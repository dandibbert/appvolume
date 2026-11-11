import AppKit
import SwiftUI

struct AppVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var manager = AudioManager.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(manager)
        } label: {
            Image(systemName: "slider.vertical.3")
                .accessibilityLabel("AppVolume")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AudioManager.shared   // 启动即应用已保存的音量，不等菜单被点开
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioManager.shared.shutdown()
    }
}
