import Foundation
import WebKit

/// 两套 Cookie 之间的桥。
///
/// 解锁之后真正要访问 DSH 界面的是 **WebView**，而 RPC / WebSocket 走的是
/// URLSession。两者各有一套 Cookie，所以握手 / 解锁拿到的 Cookie 必须
/// **转存进 WKHTTPCookieStore** —— 否则会出现「App 说解锁成功了，
/// 页面还是密码页」这种很难查的现象。
///
/// 对应 Android 侧的 `WebViewCookies` + `CookieManager`。
enum DSHCookies {

    /// 把 URLSession 那一侧（HTTPCookieStorage.shared）的 Cookie
    /// 同步进 WebView 的 CookieStore。
    static func bridgeToWebView(_ cookies: [HTTPCookie]) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            var props = cookie.properties ?? [:]
            // 去掉 Originator，避免跨源写入被拒
            props.removeValue(forKey: .init("Originator"))
            props[.init("Name")] = cookie.name
            props[.init("Value")] = cookie.value
            props[.init("Domain")] = cookie.domain
            props[.init("Path")] = cookie.path.isEmpty ? "/" : cookie.path
            props[.init("Secure")] = cookie.isSecure ? "TRUE" : "FALSE"
            props[.init("Version")] = "1"
            if let rebuilt = HTTPCookie(properties: props) {
                store.setCookie(rebuilt)
            }
        }
    }

    /// 把 URLSession 侧该 host 的全部 cookie 灌进 WebView。
    static func syncToWebView(forHost host: String) {
        guard let url = URL(string: "http://\(host)") else { return }
        bridgeToWebView(HTTPCookieStorage.shared.cookies(for: url) ?? [])
    }

    /// 读该 host 在 URLSession 侧的全部 cookie，拼成 Cookie 头。
    /// WebSocket 升级请求显式带上，不依赖 session 自动携带。
    static func cookieHeader(for host: String) -> String {
        guard let url = URL(string: "http://\(host)") else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 清掉一条连接的全部 cookie（删除连接 / 清除密码时用）。
    static func clear(forHost host: String) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.contains(host) {
                store.delete(cookie)
            }
        }
        if let url = URL(string: "http://\(host)") {
            for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }
}
