import AppKit
import SwiftUI

/// 用固定数据把弹出面板离屏渲染成 PNG，供构建流程检查界面，不需要登录图形会话。
enum Preview {
    static func render(to directory: String) -> Bool {
        _ = NSApplication.shared

        func app(_ id: String, _ name: String, _ path: String, playing: Bool) -> AudioApp {
            AudioApp(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: path),
                     isRegularApp: true, processObjects: [], isPlaying: playing)
        }
        let safari = app("safari", "Safari浏览器", "/Applications/Safari.app", playing: true)
        let music = app("music", "音乐", "/System/Applications/Music.app", playing: true)
        let facetime = app("facetime", "FaceTime通话", "/System/Applications/FaceTime.app", playing: false)
        let podcasts = app("podcasts", "播客", "/System/Applications/Podcasts.app", playing: false)
        let tv = app("tv", "视频", "/System/Applications/TV.app", playing: false)
        let settings: [String: AppSetting] = [
            "safari": AppSetting(volume: 1.6, muted: false),
            "music": AppSetting(volume: 0.45, muted: false),
            "facetime": AppSetting(volume: 0.8, muted: true),
        ]

        let scenarios: [(String, AudioManager)] = [
            ("apps", AudioManager(previewActive: [facetime, safari, music], others: [podcasts, tv],
                                  settings: settings, permission: .authorized, device: "MacBook Pro扬声器")),
            ("first-run", AudioManager(previewActive: [music], others: [podcasts],
                                       settings: [:], permission: .unknown, device: "MacBook Pro扬声器")),
            ("denied", AudioManager(previewActive: [music], others: [],
                                    settings: ["music": AppSetting(volume: 0.45)],
                                    permission: .denied, device: "AirPods Pro")),
            ("disabled", AudioManager(previewActive: [facetime, safari, music], others: [podcasts, tv],
                                      settings: settings, permission: .authorized,
                                      device: "MacBook Pro扬声器", enabled: false)),
            ("empty", AudioManager(previewActive: [], others: [], settings: [:],
                                   permission: .authorized, device: "MacBook Pro扬声器")),
        ]
        UserDefaults.standard.set(true, forKey: "showOtherApps")

        var ok = true
        for (name, manager) in scenarios {
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = PopoverView()
                    .environmentObject(manager)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearanceName)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))

                let scale = 2
                guard size.width > 0, size.height > 0,
                      let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0) else {
                    print("preview \(name)-\(suffix): no size")
                    ok = false
                    continue
                }
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png")
                if let data = rep.representation(using: .png, properties: [:]),
                   (try? data.write(to: url)) != nil {
                    print("preview \(url.lastPathComponent): \(Int(size.width))x\(Int(size.height))")
                } else {
                    ok = false
                }
            }
        }
        return ok
    }
}
