import AppKit
import Carbon.HIToolbox

/// 全局快捷键：⌃⌥⌘↑ / ⌃⌥⌘↓ 按 5% 调总音量，⌃⌥⌘M 切换总静音。
final class HotKeys {
    static let shared = HotKeys()
    static let defaultsKey = "hotKeysEnabled"
    static let summary = "⌃⌥⌘↑ ↓ 调总音量，⌃⌥⌘M 全部静音"

    private static let signature: OSType = 0x4150_5643   // "APVC"
    private static let modifiers = UInt32(cmdKey | optionKey | controlKey)

    private enum Action: UInt32 { case volumeUp = 1, volumeDown, toggleMute }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        guard enabled else { return }
        installHandler()
        register(kVK_UpArrow, .volumeUp)
        register(kVK_DownArrow, .volumeDown)
        register(kVK_ANSI_M, .toggleMute)
    }

    private func register(_ keyCode: Int, _ action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode), Self.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("AppVolume: could not register hot key %d: %d", keyCode, status)
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == HotKeys.signature,
                  let action = Action(rawValue: hotKey.id) else { return OSStatus(eventNotHandledErr) }
            HotKeys.perform(action)
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private static func perform(_ action: Action) {
        let manager = AudioManager.shared
        guard manager.isEnabled else { return }
        switch action {
        case .volumeUp: manager.nudgeMasterVolume(by: 0.05)
        case .volumeDown: manager.nudgeMasterVolume(by: -0.05)
        case .toggleMute: manager.setMasterMuted(!manager.masterMuted)
        }
    }
}
