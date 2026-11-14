import CoreAudio
import Foundation

/// 接管一组进程的音频：用 process tap 把它们原本的输出静音，
/// 再把 tap 到的音频乘以增益、经过限幅器后写到指定的输出设备。
final class TapEngine {
    static let deviceName = "AppVolume"
    private static let maxChannels = 64
    /// 增益变化的平滑时间常数。拖动、静音、接管和撤销 tap 都靠它淡入淡出，不会爆音或突变。
    private static let smoothingTime = 0.03
    private static let limiterRelease = 0.15
    /// 限幅器上限（约 -0.2 dBFS）。增益超过 100% 时压住峰值，而不是直接削波失真。
    private static let limiterCeiling: Float = 0.98

    let processObjects: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // 音频线程与主线程共享的增益。单个对齐的 Float，读写竞争无害。
    private let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let currentGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let envelope = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    // 实时线程里用的声道映射，预先分配好。
    private let sources = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: TapEngine.maxChannels)
    private let sourceStrides = UnsafeMutablePointer<Int>.allocate(capacity: TapEngine.maxChannels)
    private let outputs = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: TapEngine.maxChannels)
    private let outputStrides = UnsafeMutablePointer<Int>.allocate(capacity: TapEngine.maxChannels)

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed: \(status)" }
    }

    /// - Parameter initialGain: 开始时的增益，之后平滑过渡到 `gain`。接管正在按原音量播放的应用时用 1，
    ///   替换旧 tap 或改走另一个设备时用 0，和旧的交叉淡化。
    init(processObjects: [AudioObjectID], outputUID: String, gain: Float, initialGain: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        targetGain.initialize(to: gain)
        currentGain.initialize(to: initialGain)
        envelope.initialize(to: 0)
        do {
            try start()
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
        targetGain.deallocate()
        currentGain.deallocate()
        envelope.deallocate()
        sources.deallocate()
        sourceStrides.deallocate()
        outputs.deallocate()
        outputStrides.deallocate()
    }

    func setGain(_ gain: Float) {
        targetGain.pointee = gain
    }

    private func start() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = Self.deviceName
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw Failure(step: "CreateProcessTap", status: err) }

        let tapFormat = getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        let tapChannels: Int = {
            let n = Int(tapFormat?.mChannelsPerFrame ?? 2)
            return n > 0 ? n : 2
        }()

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.deviceName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw Failure(step: "CreateAggregateDevice", status: err) }

        var sampleRate = getProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        if sampleRate <= 0 { sampleRate = tapFormat?.mSampleRate ?? 0 }
        if sampleRate <= 0 { sampleRate = 48_000 }
        let smoothing = Float(1 - exp(-1 / (sampleRate * Self.smoothingTime)))
        let release = Float(exp(-1 / (sampleRate * Self.limiterRelease)))
        let ceiling = Self.limiterCeiling
        let maxChannels = Self.maxChannels

        let target = self.targetGain
        let current = self.currentGain
        let envelope = self.envelope
        let sources = self.sources
        let sourceStrides = self.sourceStrides
        let outputs = self.outputs
        let outputStrides = self.outputStrides

        // 直接跑在实时 IO 线程上：不能分配内存、加锁或触碰 Swift 对象。
        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)

            for ob in output {
                if let p = ob.mData { memset(p, 0, Int(ob.mDataByteSize)) }
            }

            // 聚合设备的输入 = 子设备自带的输入声道（如果有）+ tap 声道，tap 排在最后。
            var totalIn = 0
            for b in input { totalIn += Int(b.mNumberChannels) }
            let tapCh = min(tapChannels, totalIn)
            let firstTap = totalIn - tapCh

            // 立体声映射到前两个输出声道；单声道 tap 复制到所有声道。
            var count = 0
            var frames = Int.max
            var outIndex = 0
            for ob in output {
                let och = Int(ob.mNumberChannels)
                let base = outIndex
                outIndex += och
                guard och > 0, let odata = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let oframes = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * och)
                for c in 0..<och where count < maxChannels {
                    let src: Int
                    if tapCh == 1 { src = firstTap }
                    else if base + c < tapCh { src = firstTap + base + c }
                    else { continue }

                    var inBase = 0
                    for ib in input {
                        let ich = Int(ib.mNumberChannels)
                        if ich > 0, src >= inBase, src < inBase + ich,
                           let p = ib.mData?.assumingMemoryBound(to: Float.self) {
                            let iframes = Int(ib.mDataByteSize) / (MemoryLayout<Float>.size * ich)
                            sources[count] = p + (src - inBase)
                            sourceStrides[count] = ich
                            outputs[count] = odata + c
                            outputStrides[count] = och
                            frames = min(frames, oframes, iframes)
                            count += 1
                            break
                        }
                        inBase += ich
                    }
                }
            }
            guard count > 0, frames > 0, frames != Int.max else { return }

            let goal = target.pointee
            var g = current.pointee
            var env = envelope.pointee
            for i in 0..<frames {
                g += (goal - g) * smoothing
                if abs(goal - g) < 1e-5 { g = goal }

                // 各声道共用一个包络，压峰值时不改变声像。
                var peak: Float = 0
                for k in 0..<count {
                    let v = abs(sources[k][i * sourceStrides[k]] * g)
                    if v > peak { peak = v }
                }
                env = peak > env ? peak : peak + (env - peak) * release
                if env < 1e-6 { env = 0 }
                let applied = env > ceiling ? g * ceiling / env : g

                for k in 0..<count {
                    outputs[k][i * outputStrides[k]] = sources[k][i * sourceStrides[k]] * applied
                }
            }
            current.pointee = g
            envelope.pointee = env
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
        guard err == noErr else { throw Failure(step: "CreateIOProc", status: err) }
        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw Failure(step: "DeviceStart", status: err) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
