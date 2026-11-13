import AppKit
import CoreAudio
import Foundation

@main
enum Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            selfTest()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
           i + 1 < CommandLine.arguments.count {
            exit(Preview.render(to: CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// 不启动界面，只跑一遍设备和进程发现。打包流程用它确认二进制能正常运行。
    private static func selfTest() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        print("output device: \(defaultOutputDeviceName() ?? "<none>") [\(defaultOutputDeviceUID() ?? "-")]")
        print("audio capture permission: \(AudioPermission.status)")
        let objects = getObjectList(system, kAudioHardwarePropertyProcessObjectList)
        print("audio processes: \(objects.count)")
        for obj in objects {
            let pid = getProperty(obj, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
            let bundle = getString(obj, kAudioProcessPropertyBundleID) ?? "-"
            let owner = responsiblePID(for: pid).map(String.init) ?? "-"
            print("  pid \(pid) owner \(owner) \(bundle)")
        }
        print("self-test ok")
    }
}
