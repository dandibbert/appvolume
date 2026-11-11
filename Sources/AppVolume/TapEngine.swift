import CoreAudio
import Foundation

/// 接管一组进程的音频：用 process tap 把它们原本的输出静音，
/// 再把 tap 到的音频乘以增益后写回默认输出设备。
final class TapEngine {
    let processObjects: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    // 音频线程与主线程共享的增益。单个对齐的 Float，读写竞争无害。
    private let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let currentGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed: \(status)" }
    }

    init(processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        targetGain.initialize(to: gain)
        currentGain.initialize(to: gain)
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
    }

    func setGain(_ gain: Float) {
        targetGain.pointee = gain
    }

    private func start() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "AppVolume"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw Failure(step: "CreateProcessTap", status: err) }

        let tapChannels: Int = {
            let asbd = getProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            let n = Int(asbd?.mChannelsPerFrame ?? 2)
            return n > 0 ? n : 2
        }()

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolume",
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

        let target = targetGain
        let current = currentGain

        // 直接跑在实时 IO 线程上：不能分配内存、加锁或触碰 Swift 对象。
        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)

            // 聚合设备的输入 = 子设备自带的输入声道（如果有）+ tap 声道，tap 排在最后。
            var totalIn = 0
            for b in input { totalIn += Int(b.mNumberChannels) }
            let tapCh = min(tapChannels, totalIn)
            let firstTap = totalIn - tapCh

            let startGain = current.pointee
            let endGain = target.pointee

            var outIndex = 0
            for ob in output {
                let och = Int(ob.mNumberChannels)
                guard och > 0, let odata = ob.mData?.assumingMemoryBound(to: Float.self) else {
                    outIndex += och
                    continue
                }
                let oframes = Int(ob.mDataByteSize) / (MemoryLayout<Float>.size * och)

                for c in 0..<och {
                    // 立体声映射到前两个输出声道；单声道 tap 复制到所有声道。
                    var src = -1
                    if tapCh == 1 { src = firstTap }
                    else if outIndex < tapCh { src = firstTap + outIndex }
                    outIndex += 1

                    var sdata: UnsafeMutablePointer<Float>?
                    var sstride = 0
                    var sframes = 0
                    if src >= 0 {
                        var base = 0
                        for ib in input {
                            let ich = Int(ib.mNumberChannels)
                            if ich > 0, src >= base, src < base + ich,
                               let p = ib.mData?.assumingMemoryBound(to: Float.self) {
                                sdata = p + (src - base)
                                sstride = ich
                                sframes = Int(ib.mDataByteSize) / (MemoryLayout<Float>.size * ich)
                                break
                            }
                            base += ich
                        }
                    }

                    let n = min(oframes, sframes)
                    if let sdata, n > 0 {
                        // 在一个缓冲区内线性过渡增益，避免拖动滑块时出现爆音。
                        let step = (endGain - startGain) / Float(n)
                        var g = startGain
                        for i in 0..<n {
                            g += step
                            let v = sdata[i * sstride] * g
                            odata[i * och + c] = max(-1, min(1, v))
                        }
                    }
                    if n < oframes {
                        for i in max(n, 0)..<oframes { odata[i * och + c] = 0 }
                    }
                }
            }
            current.pointee = endGain
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
