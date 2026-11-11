import AppKit
import CoreAudio
import Foundation

struct AppSetting: Codable, Equatable {
    var volume: Float = 1.0   // 0.0 ... 2.0
    var muted: Bool = false

    var isDefault: Bool { volume == 1.0 && !muted }
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

    /// 正在播放、播放过、或者有自定义音量的应用。
    @Published private(set) var activeApps: [AudioApp] = []
    /// 打开了音频设备但还没出过声的其他应用。
    @Published private(set) var otherApps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
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

    private init() {
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

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

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

    func resetAll() {
        settings.removeAll()
        save()
        for engine in engines.values { engine.setGain(1.0) }
    }

    var hasCustomSettings: Bool { !settings.isEmpty }

    private func update(_ s: AppSetting, for id: String) {
        guard s != setting(for: id) else { return }
        settings[id] = s.isDefault ? nil : s
        save()
        if let engine = engines[id] {
            engine.setGain(s.gain)
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
        var app = responsiblePID(for: pid).flatMap { NSRunningApplication(processIdentifier: $0) }
        if app?.bundleIdentifier == nil {
            app = NSRunningApplication(processIdentifier: pid)
        }
        if let app, let bundleID = app.bundleIdentifier {
            return Owner(key: bundleID, name: app.localizedName ?? bundleID, icon: app.icon,
                         isRegularApp: app.activationPolicy == .regular)
        }
        let path = executablePath(for: pid)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        let key = (halBundleID?.isEmpty == false) ? halBundleID! : name
        return Owner(key: key, name: name,
                     icon: path.map { NSWorkspace.shared.icon(forFile: $0) },
                     isRegularApp: false)
    }

    // MARK: - Tap 管理

    /// 只给音量不是 100% 的应用建 tap；已建的 tap 保留到进程退出，
    /// 这样滑块经过 100% 时不会反复重建造成卡顿。
    /// 没拿到权限时不建 tap：那样只会把应用静音却放不出声音。
    private func syncEngines() {
        guard permission == .authorized, let outputUID = defaultOutputDeviceUID() else {
            engines.removeAll()
            return
        }

        for id in Array(engines.keys) where allApps[id] == nil {
            engines[id] = nil
        }

        for (id, app) in allApps {
            let s = setting(for: id)
            let existing = engines[id]
            guard existing != nil || !s.isDefault else { continue }
            if let existing, existing.processObjects == app.processObjects,
               existing.outputUID == outputUID {
                continue
            }
            engines[id] = nil   // 先销毁旧的，再建新的
            do {
                engines[id] = try TapEngine(processObjects: app.processObjects,
                                            outputUID: outputUID, gain: s.gain)
                if lastError != nil { lastError = nil }
            } catch {
                let message = "无法接管“\(app.name)”的音频（\(error)）"
                if lastError != message { lastError = message }
                NSLog("AppVolume: tap failed for %@: %@", id, String(describing: error))
            }
        }
    }
}
