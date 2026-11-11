import Foundation

/// “系统音频录制”权限。系统没有公开的查询接口，这里在运行时查找 TCC 的函数；
/// 找不到时当作已授权，让系统在第一次创建 tap 时自己弹窗。
enum AudioPermission {
    enum Status { case unknown, denied, authorized }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .authorized }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// 弹出系统授权对话框。completion 在主线程回调。
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
            completion(true)
            return
        }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
