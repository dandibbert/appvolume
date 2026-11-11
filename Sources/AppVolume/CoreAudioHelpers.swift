import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

/// 读取定长的 POD 属性。
func getProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    return err == noErr ? value : nil
}

func getString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func getObjectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let err = list.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0.baseAddress!)
    }
    guard err == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func defaultOutputDeviceUID() -> String? {
    guard let dev = getProperty(AudioObjectID(kAudioObjectSystemObject),
                                kAudioHardwarePropertyDefaultOutputDevice,
                                AudioObjectID(kAudioObjectUnknown)),
          dev != kAudioObjectUnknown else { return nil }
    return getString(dev, kAudioDevicePropertyDeviceUID)
}

func defaultOutputDeviceName() -> String? {
    guard let dev = getProperty(AudioObjectID(kAudioObjectSystemObject),
                                kAudioHardwarePropertyDefaultOutputDevice,
                                AudioObjectID(kAudioObjectUnknown)),
          dev != kAudioObjectUnknown else { return nil }
    return getString(dev, kAudioObjectPropertyName)
}

/// 找出"对该进程负责"的 pid（例如 Chrome Helper -> Chrome，WebKit GPU 进程 -> Safari）。
/// 这是私有符号，所以用 dlsym 在运行时查找，找不到就返回 nil。
func responsiblePID(for pid: pid_t) -> pid_t? {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                          "responsibility_get_pid_responsible_for_pid") else { return nil }
    let result = unsafeBitCast(sym, to: Fn.self)(pid)
    return result > 0 ? result : nil
}

func executablePath(for pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
}
