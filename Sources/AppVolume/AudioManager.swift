import AppKit
import CoreAudio
import Foundation

struct AppSetting: Codable, Equatable {
    var volume: Float = 1.0   // 0.0 ... 2.0
    var muted: Bool = false

    var gain: Float { muted ? 0 : volume }
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
    private static let defaultsKey = "appSettings"
    private static let enabledKey = "enabled"
    private static let masterVolumeKey = "masterVolume"
    private static let masterMutedKey = "masterMuted"

    /// 正在播放、播放过、或者有自定义音量的应用。
    @Published private(set) var activeApps: [AudioApp] = []
    /// 打开了音频设备但还没出过声的其他应用。
    @Published private(set) var otherApps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    /// 总开关。关掉后撤掉所有 tap，应用按原始音量播放，各自的设置保留。
    @Published private(set) var isEnabled = true
    /// 总音量：没有单独调过的应用都按它播放。拖动它会覆盖所有应用各自的音量。
    @Published private(set) var masterVolume: Float = 1.0
    /// 总静音：所有应用都不出声，各自的设置不动。
    @Published private(set) var masterMuted = false
    @Published private(set) var permission: AudioPermission.Status = .unknown
    @Published private(set) var outputDeviceName: String?
    @Published private(set) var lastError: String?

    private struct Owner {
        let key: String
        let name: String
        let icon: NSImage?
        let isRegularApp: Bool
    }

    private var engines: [String: TapEngine] = [:]
    private var ownerCache: [pid_t: Owner] = [:]
    private var allApps: [String: AudioApp] = [:]
    /// 本次运行中出过声的应用，留在主列表里，免得一暂停就从眼前消失。
    private var seenPlaying = Set<String>()
    private var timer: Timer?
    private let isPreview: Bool

    /// 只给界面预览用：填入固定数据，不接触 Core Audio。
    init(previewActive: [AudioApp], others: [AudioApp], settings: [String: AppSetting],
         permission: AudioPermission.Status, device: String?, enabled: Bool = true) {
        isPreview = true
        isEnabled = enabled
        activeApps = previewActive
        otherApps = others
        self.settings = settings
        self.permission = permission
        outputDeviceName = device
    }

    private init() {
        isPreview = false
        if UserDefaults.standard.object(forKey: Self.enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.masterVolumeKey) != nil {
            masterVolume = max(0, min(Self.maxVolume, UserDefaults.standard.float(forKey: Self.masterVolumeKey)))
        }
        masterMuted = UserDefaults.standard.bool(forKey: Self.masterMutedKey)
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }

        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.refresh()
            }
        }
        // 定时刷新"正在播放"状态，并兜底处理漏掉的通知。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: - 设置

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting(volume: masterVolume) }

    /// 实际加到应用上的增益。
    private func gain(for id: String) -> Float { masterMuted ? 0 : setting(for: id).gain }

    /// 设置总音量，并覆盖每个应用各自的音量（各自的静音保留）。
    func setMasterVolume(_ volume: Float) {
        let v = max(0, min(Self.maxVolume, volume))
        let overridden = settings.contains { $0.value.volume != v }
        guard v != masterVolume || overridden else { return }
        masterVolume = v
        settings = settings.compactMapValues { $0.muted ? AppSetting(volume: v, muted: true) : nil }
        save()
        if isPreview { return }
        UserDefaults.standard.set(v, forKey: Self.masterVolumeKey)
        applyGains()
    }

    func setMasterMuted(_ muted: Bool) {
        guard muted != masterMuted else { return }
        masterMuted = muted
        if isPreview { return }
        UserDefaults.standard.set(muted, forKey: Self.masterMutedKey)
        applyGains()
    }

    /// 总音量或总静音变了：更新已有的 tap，并给还没有 tap 的应用补上。
    private func applyGains() {
        guard isEnabled else { return }
        for (id, engine) in engines { engine.setGain(gain(for: id)) }
        if permission == .unknown {
            if masterMuted || masterVolume != 1.0 { requestPermission() }
        } else {
            syncEngines()
        }
    }

    func setVolume(_ volume: Float, for id: String) {
        var s = setting(for: id)
        s.volume = max(0, min(Self.maxVolume, volume))
        update(s, for: id)
    }

    func setMuted(_ muted: Bool, for id: String) {
        var s = setting(for: id)
        s.muted = muted
        update(s, for: id)
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
        save()
        masterVolume = 1.0
        masterMuted = false
        if isPreview { return }
        UserDefaults.standard.removeObject(forKey: Self.masterVolumeKey)
        UserDefaults.standard.removeObject(forKey: Self.masterMutedKey)
        for engine in engines.values { engine.setGain(1.0) }
    }

    var hasCustomSettings: Bool { !settings.isEmpty || masterVolume != 1.0 || masterMuted }

    private func update(_ s: AppSetting, for id: String) {
        guard s != setting(for: id) else { return }
        settings[id] = (s.volume == masterVolume && !s.muted) ? nil : s
        save()
        if isPreview || !isEnabled { return }
        if let engine = engines[id] {
            engine.setGain(gain(for: id))
        } else if permission == .unknown {
            requestPermission()
        } else {
            syncEngines()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - 权限

    private var isRequestingPermission = false

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

    func shutdown() {
        timer?.invalidate()
        engines.removeAll()
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
                ownerCache[pid] = owner
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
                     isRegularApp: false)
    }

    // MARK: - Tap 管理

    /// 只给实际增益不是 100% 的应用建 tap；已建的 tap 保留到进程退出，
    /// 这样滑块经过 100% 时不会反复重建造成卡顿。
    /// 没拿到权限时不建 tap：那样只会把应用静音却放不出声音。
    private func syncEngines() {
        guard isEnabled, permission == .authorized, let outputUID = defaultOutputDeviceUID() else {
            engines.removeAll()
            return
        }

        for id in Array(engines.keys) where allApps[id] == nil {
            engines[id] = nil
        }

        for (id, app) in allApps {
            let appGain = gain(for: id)
            let existing = engines[id]
            guard existing != nil || appGain != 1.0 else { continue }
            if let existing, existing.processObjects == app.processObjects,
               existing.outputUID == outputUID {
                continue
            }
            engines[id] = nil   // 先销毁旧的，再建新的
            do {
                engines[id] = try TapEngine(processObjects: app.processObjects,
                                            outputUID: outputUID, gain: appGain)
                if lastError != nil { lastError = nil }
            } catch {
                let message = "无法接管“\(app.name)”的音频（\(error)）"
                if lastError != message { lastError = message }
                NSLog("AppVolume: tap failed for %@: %@", id, String(describing: error))
            }
        }
    }
}
