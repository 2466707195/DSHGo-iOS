import SwiftUI
import WebKit
import Combine

/// DSH Web 端：`dsh web` 的界面跑在 WKWebView 里（插件转发端口）。
///
/// ## 三处关键处理
///
/// 1. **Cookie 桥接**：握手/解锁拿到的 `dsh-auth-…`、`dshgo-unlock` 必须
///    先转存进 `WKHTTPCookieStore`，WebView 再加载入口 ——
///    否则会出现「App 说解锁成功了，页面还是密码页」。
/// 2. **布局覆盖**：DSH 决定用抽屉布局还是电脑布局，看的是页面启动时的
///    `matchMedia('(max-width: 1023px)')`，**纯看视口宽度、只判一次**。
///    页面加载完再改已经晚了，改 CSS 也没用（判定走 JS）。
///    唯一有效的时机是在页面自己的脚本执行之前把这一次查询的返回值改掉 ——
///    `WKUserScript(at: .atDocumentStart)` 正是干这个的。
/// 3. **语音回灌**：DSH 的输入框是 `contenteditable` 富文本区，挂着编辑器自己的
///    事件监听。直接改 `textContent` 的话 DOM 变了但编辑器不知道，发送按钮还是灰的。
///    `document.execCommand('insertText')` 走浏览器原生输入路径，会正常派发事件。
final class DSHWebView: UIView, WKNavigationDelegate {

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private var bag = Set<AnyCancellable>()

    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((URL) -> Void)?
    var onNavStateChange: ((Bool, Bool) -> Void)?
    var onLoadFailed: ((String) -> Void)?

    /// 布局：nil = 交给 DSH 自己按视口宽度判定。
    var layoutMobile: Bool? = true

    override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // 布局覆盖 + polyfill 兜底：必须在页面自己的脚本之前
        controller.addUserScript(
            WKUserScript(source: Self.layoutScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: Self.polyfillScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 15.0, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        webView = WKWebView(frame: frame, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = .white
        }

        super.init(frame: frame)
        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 导航按钮 / 刷新 / 语音输入都由外部通过通知驱动
        NotificationCenter.default.publisher(for: .dshWebBack)
            .sink { [weak self] _ in self?.goBack() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .dshWebForward)
            .sink { [weak self] _ in self?.goForward() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .dshReloadBrowser)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .dshVoiceInput)
            .sink { [weak self] note in
                if let text = note.userInfo?["text"] as? String, !text.isEmpty {
                    self?.writeComposer(text)
                }
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    // MARK: - 加载

    func load(baseURL: URL) {
        // cookie 必须先转存进 WebView，再加载
        if let host = baseURL.host {
            DSHCookies.syncToWebView(forHost: host)
        }
        webView.load(URLRequest(url: baseURL))
    }

    func reload() {
        if let url = webView.url {
            load(baseURL: url)
        }
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    // MARK: - KVO

    func observe() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, change in
            if let title = change.newValue ?? nil { self?.onTitleChange?(title) }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, change in
            if let url = change.newValue ?? nil { self?.onURLChange?(url) }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
            self?.onNavStateChange?(change.newValue ?? false, self?.webView.canGoForward ?? false)
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
            self?.onNavStateChange?(self?.webView.canGoBack ?? false, change.newValue ?? false)
        })
    }

    // MARK: - 语音回灌

    /// 把识别到的文字写进 DSH 的输入框：先清空草稿（用户要的是「我说的话替换掉草稿」），
    /// 再走 `execCommand('insertText')` 派发原生输入事件。
    private func writeComposer(_ text: String) {
        let escaped = Self.escapeForJS(text)
        let js = """
        (function(){
          try {
            var all = Array.prototype.slice.call(
              document.querySelectorAll('[contenteditable="true"], textarea, input[type="text"]')
            ).filter(function(el){
              var r = el.getBoundingClientRect();
              return r.width > 8 && r.height > 8;
            });
            if (all.length === 0) return 'no-input';
            // 取可见的最后一个 —— 输入框永远在页面底部
            var el = all[all.length - 1];
            el.focus();
            var sel = window.getSelection();
            sel.removeAllRanges();
            var range = document.createRange();
            range.selectNodeContents(el);
            sel.addRange(range);
            document.execCommand('delete', false, null);
            document.execCommand('insertText', false, \(escaped));
            return 'ok';
          } catch (e) { return 'error:' + (e && e.message ? e.message : e); }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 注入脚本

    /// 布局覆盖：只截「窄屏/宽屏」这两类断言，其余原样转发。
    /// DSH 若改了断点，这段覆盖会静默失效 —— 退化成「自动」，不会把页面弄坏。
    static func layoutScript() -> String {
        let forced: String
        if let mobile = DSHWebViewLayout.mobile {
            forced = mobile ? "true" : "false"
        } else {
            forced = "null"
        }
        return """
        (function(){try{
        var F=\(forced);
        if(F!==null){
          var orig=window.matchMedia.bind(window);
          var key=function(s){return String(s).replace(/\\s+/g,'').toLowerCase()};
          window.matchMedia=function(q){
            var k=key(q),want=null;
            if(k.indexOf('(max-width:1023px)')>=0)want=F;
            else if(k.indexOf('(min-width:1024px)')>=0)want=!F;
            if(want===null||want===undefined)return orig(q);
            var ls=[];
            return{matches:want,media:String(q),onchange:null,
              addEventListener:function(t,f){if(t==='change'&&ls.indexOf(f)<0)ls.push(f)},
              removeEventListener:function(t,f){var i=ls.indexOf(f);if(i>=0)ls.splice(i,1)},
              addListener:function(f){if(ls.indexOf(f)<0)ls.push(f)},
              removeListener:function(f){var i=ls.indexOf(f);if(i>=0)ls.splice(i,1)},
              dispatchEvent:function(){return false}};
          };
        }}catch(e){}})();
        """
    }

    /// 两个 polyfill，只在缺失时定义，绝不覆盖原生实现。
    /// 正常情况下上游代理（dshgo）已经注入过，这里只是**不依赖代理的兜底**。
    static func polyfillScript() -> String {
        """
        try{if(self.crypto&&!self.crypto.randomUUID){self.crypto.randomUUID=function(){var b=new Uint8Array(16);self.crypto.getRandomValues(b);b[6]=b[6]&15|64;b[8]=b[8]&63|128;var h='';for(var i=0;i<16;i++){var x=b[i].toString(16);h+=x.length<2?'0'+x:x;if(i===3||i===5||i===7||i===9)h+='-'}return h}}}catch(e){}
        try{if(self.AbortSignal&&!self.AbortSignal.any){self.AbortSignal.any=function(signals){var ctrl=new AbortController(),list=Array.prototype.slice.call(signals||[]),done=false;function stop(s){if(done)return;done=true;try{ctrl.abort(s&&s.reason)}catch(e){ctrl.abort()}}for(var i=0;i<list.length;i++){if(list[i].aborted){stop(list[i]);break}list[i].addEventListener('abort',(function(s){return function(){stop(s)}})(list[i]),{once:true})}return ctrl.signal}}}catch(e){}
        """
    }

    /// 把文本安全地塞进 JS 字符串字面量（转义引号、反斜杠、换行、U+2028/9）。
    static func escapeForJS(_ s: String) -> String {
        var out = "'"
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            case "<": out += "\\u003c"   // 防止意外闭合脚本
            default: out.append(c)
            }
        }
        out += "'"
        return out
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }
}

/// 布局偏好：nil = 自动（DSH 自己按视口宽度判定）。
enum DSHWebViewLayout {
    static var mobile: Bool? {
        let raw = UserDefaults.standard.string(forKey: "dshgo.layout") ?? "mobile"
        switch raw {
        case "mobile": return true
        case "desktop": return false
        default: return nil
        }
    }
}

// MARK: - SwiftUI 包装

struct DSHBrowserView: UIViewRepresentable {

    let baseURL: URL
    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((URL) -> Void)?
    var onNavStateChange: ((Bool, Bool) -> Void)?
    var onLoadFailed: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DSHWebView {
        let view = DSHWebView(frame: .zero)
        view.layoutMobile = DSHWebViewLayout.mobile
        view.onTitleChange = onTitleChange
        view.onURLChange = onURLChange
        view.onNavStateChange = onNavStateChange
        view.onLoadFailed = onLoadFailed
        view.webView.navigationDelegate = context.coordinator
        context.coordinator.onLoadFailed = onLoadFailed
        view.observe()
        view.load(baseURL: baseURL)
        return view
    }

    func updateUIView(_ uiView: DSHWebView, context: Context) {
        // 连接切换后地址变了必须重载，否则浏览器 Tab 还显示着上一台电脑的页面。
        // 只在「还没加载过」或「地址真的变了」时重载，避免每次刷新都打断正在写的输入框。
        let current = uiView.webView.url?.absoluteString
        if current == nil || current != baseURL.absoluteString {
            uiView.layoutMobile = DSHWebViewLayout.mobile
            uiView.load(baseURL: baseURL)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {

        /// 外层回调（失败时 BrowserScreen 显示原生错误页，而不是一片空白）。
        var onLoadFailed: ((String) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 首屏 DOM 就绪后注入 polyfill（正常情况下上游代理已经注入过，
            // 这里只是不依赖代理的兜底；布局覆盖走的是 WKUserScript，在页面脚本之前）
            injectPolyfills(webView)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onLoadFailed?(error.localizedDescription)
        }
    }
}

extension Notification.Name {
    /// 地址栏的后退 / 前进按钮 → WebView（见 DSHWebView 里的订阅）
    static let dshWebBack = Notification.Name("dshWebBack")
    static let dshWebForward = Notification.Name("dshWebForward")
}
