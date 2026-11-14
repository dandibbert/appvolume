import AppKit
import CoreAudio
import Foundation

struct AppSetting: Codable, Equatable {
    /// 滑块位置 0.0 ... 2.0，相对于总音量。实际增益见 `AudioManager.taper`。
    var volume: Float = 1.0
    var muted: Bool = false
    /// 定时静音的结束时间；到点自动取消静音。
    var mutedUntil: Date?
    /// 指定的输出设备；nil 表示跟随系统默认输出。设备不在时临时回到默认输出。
    var outputUID: String?
    /// 设备断开后仍能在菜单里显示它的名字。
    var outputName: String?

    var isDefault: Bool { volume == 1 && !muted && outputUID == nil }
}

struct AudioApp: Identifiable, Equatable {
    let id: String            // 所属应用的 bundle ID，也是保存偏好的 key
    let name: String
    let icon: NSImage?
    let isRegularApp: Bool
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

final class AudioManager: ObservableObject {
    static let shared = AudioManager()
    static let maxVolume: Float = 2.0
    /// 总音量 × 应用音量之后的增益上限。超过 1 的部分由 TapEngine 的限幅器压住峰值。
    static let maxGain: Float = 2.0
    /// 音量回到 100% 且走默认输出后，tap 再留这么久才撤，免得滑块经过 100% 时反复重建。
    private static let idleTapLifetime: TimeInterval = 5
    /// 撤掉的 tap 先淡到目标音量，过这么久再销毁。
    private static let fadeTime: TimeInterval = 0.25
    private static let defaultsKey = "appSettings"
    private static let enabledKey = "enabled"
    private static let masterVolumeKey = "masterVolume"
    private static let masterMutedKey = "masterMuted"

    /// 正在播放、播放过、或者有自定义设置的应用。
    @Published private(set) var activeApps: [AudioApp] = []
    /// 打开了音频设备但还没出过声的其他应用。
    @Published private(set) var otherApps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    /// 总开关。关掉后撤掉所有 tap，应用按原始音量播放，各自的设置保留。
    @Published private(set) var isEnabled = true
    /// 总音量，按比例作用在所有应用上：实际增益 = 总音量 × 应用音量。不改动各应用自己的设置。
    @Published private(set) var masterVolume: Float = 1.0
    /// 总静音，优先于各应用的设置：所有应用都不出声，各自的设置不动。
    @Published private(set) var masterMuted = false
    @Published private(set) var permission: AudioPermission.Status = .unknown
    @Published private(set) var outputDeviceName: String?
    @Published private(set) var outputDevices: [OutputDevice] = []
    /// 按应用记录的接管失败原因，应用退出或接管成功后清掉。
    @Published private(set) var errors: [String: String] = [:]

    private struct Owner {
        let key: String
        let name: String
        let icon: NSImage?
        let isRegularApp: Bool
        /// 只按可执行文件名认出来的归属。应用可能还没注册完，下次再认一次，不缓存。
        var isProvisional = false
    }

    private struct TapFailure {
        let attempts: Int
        let retryAt: Date
    }

    private var engines: [String: TapEngine] = [:]
    /// 正在淡出、稍后销毁的 tap。
    private var retiring: [TapEngine] = []
    private var idleSince: [String: Date] = [:]
    private var failures: [String: TapFailure] = [:]
    private var ownerCache: [pid_t: Owner] = [:]
    private var allApps: [String: AudioApp] = [:]
    /// 本次运行中出过声的应用，留在主列表里，免得一暂停就从眼前消失。
    private var seenPlaying = Set<String>()
    private var timer: Timer?
    private var pendingSave: DispatchWorkItem?
    private let isPreview: Bool

    /// 只给界面预览用：填入固定数据，不接触 Core Audio。
    init(previewActive: [AudioApp], others: [AudioApp], settings: [String: AppSetting],
         permission: AudioPermission.Status, device: String?, devices: [OutputDevice] = [],
         enabled: Bool = true, masterVolume: Float = 1.0, masterMuted: Bool = false,
         errors: [String: String] = [:]) {
        isPreview = true
        isEnabled = enabled
        activeApps = previewActive
        otherApps = others
        self.settings = settings
        self.permission = permission
        self.masterVolume = masterVolume
        self.masterMuted = masterMuted
        self.errors = errors
        outputDeviceName = device
        outputDevices = devices
    }

    private init() {
        isPreview = false
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) != nil {
            isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        if defaults.object(forKey: Self.masterVolumeKey) != nil {
            masterVolume = max(0, min(Self.maxVolume, defaults.float(forKey: Self.masterVolumeKey)))
        }
        masterMuted = defaults.bool(forKey: Self.masterMutedKey)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved.filter { !$0.value.isDefault }
        }

        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.refresh()
            }
        }
        // 定时刷新"正在播放"状态和定时静音，并兜底处理漏掉的通知。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: - 设置

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    /// 滑块位置到线性增益。100% 以下按平方曲线，小音量区间更好调；100% 以上线性升到 2 倍。
    static func taper(_ position: Float) -> Float { position <= 1 ? position * position : position }

    /// 实际加到应用上的增益。总静音优先于一切。
    private func gain(for id: String) -> Float {
        let s = setting(for: id)
        if masterMuted || s.muted { return 0 }
        return min(Self.maxGain, Self.taper(masterVolume) * Self.taper(s.volume))
    }

    /// 应用指定的、当前连着的输出设备。
    private func routedOutputUID(for id: String) -> String? {
        guard let uid = settings[id]?.outputUID, outputDevices.contains(where: { $0.uid == uid }) else { return nil }
        return uid
    }

    /// 应用指定了输出设备时返回设备名；设备没连着时 `connected` 为 false。
    func routedOutput(for id: String) -> (name: String, connected: Bool)? {
        guard let uid = settings[id]?.outputUID else { return nil }
        if let device = outputDevices.first(where: { $0.uid == uid }) { return (device.name, true) }
        return (settings[id]?.outputName ?? uid, false)
    }

    func setMasterVolume(_ volume: Float) {
        let v = max(0, min(Self.maxVolume, volume))
        guard v != masterVolume else { return }
        masterVolume = v
        save()
        applyChanges()
    }

    /// 快捷键用：按 5% 一档调总音量，调大时顺便取消总静音。
    func nudgeMasterVolume(by delta: Float) {
        if delta > 0 { setMasterMuted(false) }
        let step: Float = 0.05
        setMasterVolume(((masterVolume + delta) / step).rounded() * step)
    }

    func setMasterMuted(_ muted: Bool) {
        guard muted != masterMuted else { return }
        masterMuted = muted
        save()
        applyChanges()
    }

    func setVolume(_ volume: Float, for id: String) {
        var s = setting(for: id)
        s.volume = max(0, min(Self.maxVolume, volume))
        update(s, for: id)
    }

    /// - Parameter duration: 定时静音的时长，到点自动恢复；nil 表示一直静音到手动取消。
    func setMuted(_ muted: Bool, for id: String, duration: TimeInterval? = nil) {
        var s = setting(for: id)
        s.muted = muted
        s.mutedUntil = muted ? duration.map { Date().addingTimeInterval($0) } : nil
        update(s, for: id)
    }

    /// nil 表示跟随系统默认输出。
    func setOutput(_ device: OutputDevice?, for id: String) {
        var s = setting(for: id)
        s.outputUID = device?.uid
        s.outputName = device?.name
        update(s, for: id)
    }

    func resetSetting(for id: String) {
        update(AppSetting(), for: id)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if isPreview { return }
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        refresh()
    }

    func resetAll() {
        settings.removeAll()
        masterVolume = 1.0
        masterMuted = false
        save()
        applyChanges()
    }

    var hasCustomSettings: Bool { !settings.isEmpty || masterVolume != 1.0 || masterMuted }

    private func update(_ s: AppSetting, for id: String) {
        guard s != setting(for: id) else { return }
        settings[id] = s.isDefault ? nil : s
        save()
        applyChanges()
    }

    /// 设置变了：调整已有 tap 的增益，按需建或撤 tap。用户主动调节时才弹权限请求。
    private func applyChanges() {
        guard !isPreview, isEnabled else { return }
        if permission == .unknown, hasCustomSettings { requestPermission() }
        syncEngines()
    }

    /// 拖动滑块时设置变化很密，合并成一次写入。
    private func save() {
        guard !isPreview else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func persist() {
        pendingSave = nil
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        defaults.set(masterVolume, forKey: Self.masterVolumeKey)
        defaults.set(masterMuted, forKey: Self.masterMutedKey)
    }

    private func expireTimedMutes() {
        let now = Date()
        var changed = false
        for (id, s) in settings {
            guard let until = s.mutedUntil, until <= now else { continue }
            var unmuted = s
            unmuted.muted = false
            unmuted.mutedUntil = nil
            settings[id] = unmuted.isDefault ? nil : unmuted
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 权限

    private var isRequestingPermission = false
    /// 启动时如果有保存的设置却没权限，自动请求一次；之后只在用户操作时请求，免得反复弹窗。
    private var didAutoRequestPermission = false

    func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        AudioPermission.request { [weak self] granted in
            guard let self else { return }
            self.isRequestingPermission = false
            self.permission = granted ? .authorized : AudioPermission.status
            self.refresh()
        }
    }

    /// 退出前把所有应用淡回原始音量，再撤掉 tap。
    func shutdown() {
        timer?.invalidate()
        if let pendingSave {
            pendingSave.cancel()
            persist()
        }
        let hadEngines = !engines.isEmpty
        retireAll()
        if hadEngines { Thread.sleep(forTimeInterval: Self.fadeTime) }
        retiring.removeAll()
    }

    // MARK: - 进程发现

    func refresh() {
        guard !isPreview else { return }
        let status = AudioPermission.status
        if status != permission, !(permission == .authorized && status == .unknown) {
            permission = status
        }
        let deviceName = defaultOutputDeviceName()
        if deviceName != outputDeviceName { outputDeviceName = deviceName }
        let devices = listOutputDevices()
        if devices != outputDevices { outputDevices = devices }
        expireTimedMutes()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let objects = getObjectList(AudioObjectID(kAudioObjectSystemObject),
                                    kAudioHardwarePropertyProcessObjectList)

        var grouped: [String: AudioApp] = [:]
        var livePIDs = Set<pid_t>()

        for obj in objects {
            guard let pid = getProperty(obj, kAudioProcessPropertyPID, pid_t(-1)),
                  pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let owner: Owner
            if let cached = ownerCache[pid] {
                owner = cached
            } else {
                owner = resolveOwner(pid: pid, halBundleID: getString(obj, kAudioProcessPropertyBundleID))
                if !owner.isProvisional { ownerCache[pid] = owner }
            }
            let playing = (getProperty(obj, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0

            if var app = grouped[owner.key] {
                app.processObjects.append(obj)
                app.isPlaying = app.isPlaying || playing
                grouped[owner.key] = app
            } else {
                grouped[owner.key] = AudioApp(id: owner.key, name: owner.name, icon: owner.icon,
                                              isRegularApp: owner.isRegularApp,
                                              processObjects: [obj], isPlaying: playing)
            }
        }
        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }
        for key in Array(grouped.keys) { grouped[key]?.processObjects.sort() }
        allApps = grouped

        seenPlaying.formIntersection(grouped.keys)
        for app in grouped.values where app.isPlaying { seenPlaying.insert(app.id) }

        func byName(_ a: AudioApp, _ b: AudioApp) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let active = grouped.values
            .filter { seenPlaying.contains($0.id) || settings[$0.id] != nil }
            .sorted(by: byName)
        let activeIDs = Set(active.map(\.id))
        let others = grouped.values
            .filter { !activeIDs.contains($0.id) && $0.isRegularApp }
            .sorted(by: byName)
        if active != activeApps { activeApps = active }
        if others != otherApps { otherApps = others }

        syncEngines()
    }

    private func resolveOwner(pid: pid_t, halBundleID: String?) -> Owner {
        let path = executablePath(for: pid)
        if let app = responsiblePID(for: pid).flatMap({ NSRunningApplication(processIdentifier: $0) }),
           let bundleID = app.bundleIdentifier {
            return Owner(key: bundleID, name: app.localizedName ?? bundleID, icon: app.icon,
                         isRegularApp: app.activationPolicy == .regular)
        }
        // 查不到负责进程时，按可执行文件所在的最外层 .app 归属（Foo.app/Contents/.../Helper.app）。
        if let path, let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            if let bundle = Bundle(path: bundlePath), let bundleID = bundle.bundleIdentifier {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
                let name = running?.localizedName
                    ?? FileManager.default.displayName(atPath: bundlePath).replacingOccurrences(of: ".app", with: "")
                return Owner(key: bundleID, name: name,
                             icon: NSWorkspace.shared.icon(forFile: bundlePath),
                             isRegularApp: running.map { $0.activationPolicy == .regular } ?? true)
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            return Owner(key: bundleID, name: app.localizedName ?? bundleID, icon: app.icon,
                         isRegularApp: app.activationPolicy == .regular)
        }
        let name = path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        let key = (halBundleID?.isEmpty == false) ? halBundleID! : name
        return Owner(key: key, name: name,
                     icon: path.map { NSWorkspace.shared.icon(forFile: $0) },
                     isRegularApp: false, isProvisional: halBundleID?.isEmpty != false)
    }

    // MARK: - Tap 管理

    /// 每个应用的 tap 只有三种去向：
    /// - 不需要（增益 100% 且走默认输出）：已有的 tap 闲置一会儿后淡回原音量再撤；
    /// - 需要且 tap 还对得上（进程和输出设备都没变）：只改增益；
    /// - 需要但对不上或没有：新建一个，和旧的交叉淡化。建失败就按指数退避重试。
    /// 没拿到权限时不建 tap：那样只会把应用静音却放不出声音。
    private func syncEngines() {
        guard isEnabled, permission == .authorized, let defaultUID = defaultOutputDeviceUID() else {
            if isEnabled, permission == .unknown, hasCustomSettings, !didAutoRequestPermission {
                didAutoRequestPermission = true
                requestPermission()
            }
            retireAll()
            failures.removeAll()
            if !errors.isEmpty { errors.removeAll() }
            return
        }

        let now = Date()
        var newErrors = errors.filter { allApps[$0.key] != nil }
        failures = failures.filter { allApps[$0.key] != nil }

        // 进程都退出了，没有声音可接管，直接销毁。
        for id in Array(engines.keys) where allApps[id] == nil {
            engines[id] = nil
        }
        idleSince = idleSince.filter { engines[$0.key] != nil }

        for (id, app) in allApps {
            let appGain = gain(for: id)
            let outputUID = routedOutputUID(for: id) ?? defaultUID
            let existing = engines[id]

            if appGain == 1, outputUID == defaultUID {
                newErrors[id] = nil
                failures[id] = nil
                guard let existing else { continue }
                existing.setGain(1)
                let since = idleSince[id] ?? now
                idleSince[id] = since
                if existing.outputUID != defaultUID || now.timeIntervalSince(since) >= Self.idleTapLifetime {
                    engines[id] = nil
                    idleSince[id] = nil
                    retire(existing, defaultUID: defaultUID)
                }
                continue
            }
            idleSince[id] = nil

            if let existing, existing.processObjects == app.processObjects, existing.outputUID == outputUID {
                existing.setGain(appGain)
                continue
            }
            existing?.setGain(appGain)
            if let failure = failures[id], failure.retryAt > now { continue }

            do {
                let takingOver = existing == nil && outputUID == defaultUID
                let engine = try TapEngine(processObjects: app.processObjects, outputUID: outputUID,
                                           gain: appGain, initialGain: takingOver ? 1 : 0)
                if let existing { retire(existing, fadingTo: 0) }
                engines[id] = engine
                failures[id] = nil
                newErrors[id] = nil
            } catch {
                let attempts = (failures[id]?.attempts ?? 0) + 1
                let delay = min(60, pow(2, Double(attempts)))
                failures[id] = TapFailure(attempts: attempts, retryAt: now.addingTimeInterval(delay))
                newErrors[id] = "无法接管“\(app.name)”的音频（\(error)）"
                NSLog("AppVolume: tap failed for %@: %@", id, String(describing: error))
            }
        }
        if newErrors != errors { errors = newErrors }
    }

    /// 走默认输出的 tap 淡回原音量（之后原始声音无缝接上），走别的设备的淡出。
    private func retire(_ engine: TapEngine, defaultUID: String?) {
        retire(engine, fadingTo: engine.outputUID == defaultUID ? 1 : 0)
    }

    private func retire(_ engine: TapEngine, fadingTo gain: Float) {
        engine.setGain(gain)
        retiring.append(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeTime) { [weak self, weak engine] in
            self?.retiring.removeAll { $0 === engine }
        }
    }

    private func retireAll() {
        guard !engines.isEmpty else { return }
        let defaultUID = defaultOutputDeviceUID()
        for engine in engines.values { retire(engine, defaultUID: defaultUID) }
        engines.removeAll()
        idleSince.removeAll()
    }
}
