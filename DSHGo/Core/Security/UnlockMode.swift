import Foundation
import LocalAuthentication

/// 解锁方式四档。
///
/// 密码是**根凭据**：第一次必须先输一次，之后才是指纹/人脸/设备密码。
/// 选了「每次输密码」则本机不存密码，每次都要打 —— 最严的一档。
enum UnlockMode: String, CaseIterable, Identifiable {
    /// 自动：存密码，下次直接进（仍然要求先手动输过一次）
    case auto
    /// 仅指纹人脸
    case biometricOnly
    /// 仅设备密码
    case passcodeOnly
    /// 每次输密码：本机不存
    case passwordEveryTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .biometricOnly: return "仅指纹人脸"
        case .passcodeOnly: return "仅设备密码"
        case .passwordEveryTime: return "每次输密码"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "存密码，下次连接直接进。第一次仍然要手动输一次。"
        case .biometricOnly:
            return "取已存的密码前要过指纹或面容。"
        case .passcodeOnly:
            return "取已存的密码前要过设备密码。"
        case .passwordEveryTime:
            return "本机不存密码，每次连接都要打一遍 —— 最严的一档。"
        }
    }

    /// 这一档要不要把密码落到 Keychain。
    var persistsPassword: Bool {
        self != .passwordEveryTime
    }

    /// LAContext 的校验策略；nil = 不校验，直接读已存的密码。
    var policy: LAPolicy? {
        switch self {
        case .auto, .passwordEveryTime: return nil
        case .biometricOnly: return .deviceOwnerAuthenticationWithBiometrics
        case .passcodeOnly: return .deviceOwnerAuthentication
        }
    }
}

/// 解锁偏好的持久化（密码本身在 Keychain，这里只存档位）。
enum UnlockPreferences {

    private static let key = "dshgo.unlockMode"

    static var mode: UnlockMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? UnlockMode.auto.rawValue
            return UnlockMode(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// 生物识别的可用性 + 取已存密码的一次调用。
enum BiometricUnlock {

    /// 这台设备当前档位能不能免手输。
    static func isAvailable(for mode: UnlockMode) -> Bool {
        guard let policy = mode.policy else { return false }
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(policy, error: &error)
    }

    /// 过生物识别/设备密码，取回已存的访问密码。
    /// - Parameters:
    ///   - mode: 当前档位（`.auto` 不校验直接返回）
    ///   - account: Keychain 账号（连接 id）
    ///   - reason: 系统弹窗上显示的理由
    static func loadPassword(mode: UnlockMode, account: String, reason: String) async -> String? {
        guard let policy = mode.policy else {
            return Keychain.load(account: account)
        }
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return nil }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                c.resume(returning: success)
            }
        }
        guard ok else { return nil }
        return Keychain.load(account: account)
    }

    /// 系统弹窗上的文案：当前档位用哪种。
    static func reason(for computer: String) -> String {
        "解锁 \(computer) 的访问密码"
    }
}
