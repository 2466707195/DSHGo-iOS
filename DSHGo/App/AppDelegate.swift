import UIKit
import UserNotifications

/// 通知栏的两个动作：**点按钮不会把 App 拉到前台** ——
/// 你的意图只是点个头，不是要去看 DSH。
///
/// 对应 Android 的 `ApprovalReceiver` + `NotificationCenter`。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // ★ 没有这一句，通知一条都不会出现 —— `add(_:)` 会被静默丢掉。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        // 带动作的通知分类：允许 / 拒绝
        let allow = UNNotificationAction(
            identifier: "DSH_ALLOW",
            title: "允许",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: "DSH_DENY",
            title: "拒绝",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: "DSH_APPROVAL",
            actions: [allow, deny],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        return true
    }

    /// 前台时也弹通知（timeSensitive 由 content 指定）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// 点通知按钮 → 回答审批。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case "DSH_ALLOW":
            NotificationCenter.default.post(name: .dshApproveFromNotification, object: nil, userInfo: userInfo)
        case "DSH_DENY":
            NotificationCenter.default.post(name: .dshRejectFromNotification, object: nil, userInfo: userInfo)
        default:
            break
        }
        completionHandler()
    }

    // MARK: - 长按图标快捷菜单

    /// 新会话 / 继续最近 / 设置 —— 静态项在 project.yml 的
    /// `UIApplicationShortcutItems` 里声明，这里只负责接住点击。
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let name: Notification.Name
        switch shortcutItem.type {
        case "com.dshgo.shortcut.newSession":
            name = .dshShortcutNewSession
        case "com.dshgo.shortcut.recent":
            name = .dshShortcutRecent
        case "com.dshgo.shortcut.settings":
            name = .dshShortcutSettings
        default:
            completionHandler(false)
            return
        }
        NotificationCenter.default.post(name: name, object: nil)
        completionHandler(true)
    }
}

extension Notification.Name {
    static let dshShortcutNewSession = Notification.Name("dshShortcutNewSession")
    static let dshShortcutRecent = Notification.Name("dshShortcutRecent")
    static let dshShortcutSettings = Notification.Name("dshShortcutSettings")
}
