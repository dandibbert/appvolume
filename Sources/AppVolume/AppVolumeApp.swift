import AppKit
import Combine
import SwiftUI

/// 菜单栏图标和弹出面板。用 NSStatusItem + NSPopover，面板的圆角、材质和箭头都交给系统绘制。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var enabledObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = AudioManager.shared   // 启动即应用已保存的音量，不等菜单被点开

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3",
                                accessibilityDescription: "AppVolume")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        // 总开关关掉时，菜单栏图标变淡。
        enabledObserver = manager.$isEnabled.sink { [weak item] enabled in
            item?.button?.appearsDisabled = !enabled
        }

        let host = NSHostingController(rootView: PopoverView().environmentObject(manager))
        host.sizingOptions = [.preferredContentSize]   // 列表展开、收起时面板跟着变高
        popover.contentViewController = host
        popover.behavior = .transient
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioManager.shared.shutdown()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        AudioManager.shared.refresh()
        // 不激活的话，点面板外面不会自动收起。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
