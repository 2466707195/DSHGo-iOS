import Foundation
import Combine
import UIKit
import UserNotifications

/// 与 DSH 说话 —— 协议按 `android/docs/PROTOCOL.md`（实测验证）复刻。
///
/// ## 三条通路
///
/// 1. **握手**：GET 入口地址，跟重定向、收 `Set-Cookie: dsh-auth-…`。
///    在原生侧先把这一跳走完，WebView 再一次性加载入口 —— 首屏直接就是 GUI。
/// 2. **一元 RPC**：`POST /api/<ns>/<method>`，
///    信封 `{type:'client-request', rpcId, method, payload:{args}}`。
///    只用来启动时拉一次全量会话（事件里不带标题）。
/// 3. **事件流**：`ws://…/api/remote.mux`，发
///    `{type:'open', streamId, endpoint:'$events', payload:{args:{}}}`。
///
/// ## 为什么要回执 waterfall
///
/// `approval/request`（工具审批）是 waterfall 模式：宿主会等每个订阅者表态。
/// 会话内的 DSH 网页本来就在订阅同一条流 —— 原生侧再订一条却**不回执**的话，
/// 宿主的 waterfall 会一直挂着，**把用户的审批卡住**。
/// 所以对每个不接管的 waterfall 帧立刻回 `{kind:'next'}`。
@MainActor
final class DSHTransport: ObservableObject {

    // MARK: - 常量

    /// 让宿主知道这是 App —— 决定它给 JSON 还是给密码页（只影响界面，不影响权限）。
    static let appUA = "DSHGo/1.0 (iOS)"

    /// 握手/探测用桌面级 UA：握手注入与 dsh web 的首屏都按普通浏览器对待。
    static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 DshRemote/1.0"

    private static let unlockPath = "/__dshgo__/unlock"
    private static let statusPath = "/__dshgo__/auth/status"
    private static let infoPath = "/__dshgo__/info"

    // MARK: - 发布状态

    @Published private(set) var sessions: [DSHSession] = []
    @Published private(set) var isEventStreamLive = false
    @Published private(set) var isSnapshotting = false
    @Published private(set) var error: String?
    @Published private(set) var lastCookieInfo = "（还没试过）"
    @Published private(set) var clientId: String?
    /// 事件流的工作模式：流 / 轮询兜底 / 断了。
    @Published private(set) var mode: Mode = .stream

    /// `/__dshgo__/info` 的可用字段（多地址选路 + 更新提示都靠它）。
    struct Probe: Equatable {
        let addresses: [String]
        let tailscale: [String]
        let upstreamPort: Int
        let updateAvailable: Bool
        let latestVersion: String?
    }

    @Published private(set) var probe: Probe?

    enum Mode: Equatable {
        case stream      // WebSocket 事件流
        case poll        // 轮询兜底（服务端没有 remote.mux，或流连不上）
        case down        // 彻底断了
    }

    let computer: DSHComputer

    /// 会话事件（新增/状态变化/审批）→ AppModel 冒泡给 UI + 本地通知。
    var onSessionEvent: (@MainActor (DSHSession) -> Void)?

    /// 收到审批请求时回调。返回 true = 已经接管（宿主会挂着等这条）；
    /// 返回 false 立刻回 `next`，交回给网页那条链路。
    var onApproval: (@MainActor (ApprovalAsk) -> Bool)?

    private let session: URLSession
    /// 握手专用：手写跳转上限，避免上游 303 循环把请求挂死。
    private let handshakeSession: URLSession
    private var ws: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private var stopped = false
    /// WebSocket 连续失败次数。2 次基本可判定服务端没有这条路由 → 退轮询。
    private var wsFailures = 0

    init(computer: DSHComputer) {
        self.computer = computer

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        // 握手跟 Android 的 Handshake.java 一样：**每一跳都带上已收到的 cookie**。
        // 不带就会 303 → / → 303 无限循环（launch token 换 cookie 后上游回 303，
        // location 是相对路径 `/`）。URLSession 的 httpShouldSetCookies 会自动带上，
        // 这里再加一层跳数上限兜底。
        let hsConfig = URLSessionConfiguration.default
        hsConfig.httpCookieStorage = .shared
        hsConfig.httpShouldSetCookies = true
        hsConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        hsConfig.waitsForConnectivity = false
        self.handshakeSession = URLSession(
            configuration: hsConfig,
            delegate: RedirectCapper(maxHops: 6),
            delegateQueue: nil
        )

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    self.startEvents()
                }
            }
            .store(in: &bag)
    }

    deinit {
        stopped = true
        receiveTask?.cancel()
        reconnectTask?.cancel()
        pollTask?.cancel()
        pingTask?.cancel()
    }

    /// 重新启用（切回这条连接时用）：之前的 stopEvents 会把它关掉。
    func restart() {
        stopped = false
        startEvents()
    }

    // MARK: - 基础 URL

    private var base: String {
        computer.activeAddress.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - 握手

    enum HandshakeResult {
        case ok(cookieCount: Int, authCount: Int)
        case failed(String)

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    /// 原生握手：GET 入口地址，让 URLSession 跟完重定向，
    /// `Set-Cookie` 由系统 cookie 引擎自动收进 `HTTPCookieStorage.shared`。
    ///
    /// 之后把 cookie 桥接进 WebView 的 CookieStore，WebView 再一次性加载入口 ——
    /// 首屏直接就是 GUI，无过渡页、无多余历史。
    func handshake() async -> HandshakeResult {
        guard let url = URL(string: base) else { return .failed("地址格式不对") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 12

        do {
            _ = try await handshakeSession.data(for: request)
            let (count, authCount) = cookieCounts()
            lastCookieInfo = count > 0
                ? "cookie \(count) 条（其中 dsh-auth \(authCount) 条）"
                : "握手成功但没收到 cookie"
            // 桥接给 WebView：解锁/握手拿到的 Cookie 必须转存，否则页面还是密码页
            DSHCookies.syncToWebView(forHost: computer.host)
            return .ok(cookieCount: count, authCount: authCount)
        } catch {
            return .failed(describe(error))
        }
    }

    private func cookieCounts() -> (Int, Int) {
        guard let url = URL(string: base) else { return (0, 0) }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return (cookies.count, cookies.filter { $0.name.hasPrefix("dsh-auth") }.count)
    }

    // MARK: - 探测（不需要先解锁）

    enum ProbeOutcome {
        /// 在线。[ms] 往返耗时，[version] 插件版本。
        case online(ms: Int, version: String?, needsPassword: Bool, listening: Bool, upstreamPort: Int)
        /// 地址通但不是 dshgo 的转发层。
        case notDshgo
        /// 在线但被闸门挡着（设了访问密码且没有解锁 Cookie）。
        case locked
        case failed(String)

        var isOnline: Bool {
            switch self {
            case .online, .locked: return true
            case .notDshgo, .failed: return false
            }
        }
    }

    /// 打插件自己注册的两个端点：
    /// `/__dshgo__/auth/status`（闸门白名单，不需要先解锁）+ `/__dshgo__/info`。
    /// 所以列表里那些从没登录过的 DSH，也能显示在线/版本/要不要密码。
    func probe(timeout: TimeInterval = 2.5) async -> ProbeOutcome {
        let started = Date()

        // 先问密码状态：它是白名单路径，通不了说明地址根本不通
        let needsPassword: Bool
        do {
            let (data, response) = try await getJSON(path: Self.statusPath, timeout: timeout)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            needsPassword = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hasPassword"] as? Bool) ?? false
        } catch {
            return .failed(describe(error))
        }

        // 再问 info：设了密码且没有解锁 Cookie 时它会被闸门挡回来（401）
        do {
            let (data, response) = try await getJSON(path: Self.infoPath, timeout: timeout)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                return .locked
            }
            guard status == 200 else {
                return .failed("HTTP \(status)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("响应不是 JSON")
            }
            // 确认对面确实是 dshgo 的转发层，而不是同网段某个碰巧开了端口的东西
            guard (json["name"] as? String) == "dshgo" else {
                return .notDshgo
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let payload = Probe(
                addresses: json["addresses"] as? [String] ?? [],
                tailscale: json["tailscale"] as? [String] ?? [],
                upstreamPort: json["upstreamPort"] as? Int ?? 0,
                updateAvailable: json["updateAvailable"] as? Bool ?? false,
                latestVersion: json["latestVersion"] as? String
            )
            probe = payload
            return .online(
                ms: ms,
                version: json["version"] as? String,
                needsPassword: needsPassword,
                listening: json["listening"] as? Bool ?? false,
                upstreamPort: payload.upstreamPort
            )
        } catch {
            return .failed(describe(error))
        }
    }

    private func getJSON(path: String, timeout: TimeInterval, cookie: String? = nil) async throws -> (Data, URLResponse) {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return try await session.data(for: request)
    }

    // MARK: - 解锁

    enum UnlockResult {
        /// 宿主没设密码，直接进。
        case notRequired
        /// 解锁成功，Cookie 已桥接给 WebView。
        case ok
        /// 密码不对 —— 调用方应该清掉本机存的、重新问用户。
        case badPassword
        case failed(String)
    }

    /// 交密码换解锁 Cookie（`dshgo-unlock`）。
    /// 拿到的 Cookie 必须转存进 WebView 的 CookieStore，否则页面还是密码页。
    func unlock(password: String) async -> UnlockResult {
        guard let url = URL(string: base + Self.unlockPath) else { return .failed("地址格式不对") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appUA, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["password": password])

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                DSHCookies.syncToWebView(forHost: computer.host)
                return .ok
            case 401:
                return .badPassword
            case 404:
                // 宿主上根本没有这个端点 = 旧版插件或者没设密码
                return .notRequired
            default:
                return .failed("宿主返回 HTTP \(status)")
            }
        } catch {
            return .failed(describe(error))
        }
    }

    // MARK: - 一元 RPC

    enum RPCError: Error {
        case badJSON(String)
        case badEnvelope(String)
        case server(code: String, message: String)
        case http(Int, String)

        var httpCode: Int {
            if case .http(let code, _) = self { return code }
            return 0
        }
    }

    /// `POST /api/<ns>/<method>`，端点用斜杠（点号会得到 invalid Remote endpoint）。
    private func unary(_ endpoint: String, args: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(base)/api/\(endpoint)") else {
            throw RPCError.badEnvelope("地址格式不对")
        }
        let envelope: [String: Any] = [
            "type": "client-request",
            "rpcId": UUID().uuidString,
            "method": endpoint,
            "payload": ["args": args]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.appUA, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: envelope)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RPCError.http(status, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw RPCError.badEnvelope(String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard result["ok"] as? Bool == true else {
            let err = result["error"] as? [String: Any]
            throw RPCError.server(
                code: err?["code"] as? String ?? "unknown",
                message: err?["message"] as? String ?? "未知错误"
            )
        }
        return result["value"] as? [String: Any] ?? [:]
    }

    // MARK: - 会话快照

    /// 拉一次全量会话：事件流里只带 sessionId + running，**没有标题**，
    /// 通知要说「『检查库存字段』跑完了」就得先有这张对照表。
    @discardableResult
    func snapshot() async -> Bool {
        isSnapshotting = true
        defer { isSnapshotting = false }
        do {
            let value = try await unary("session/list", args: ["_request": [:]])
            let items = value["items"] as? [[String: Any]] ?? []
            var next: [DSHSession] = []
            for item in items {
                guard let id = item["sessionId"] as? String else { continue }
                let title = (item["projections"] as? [String: Any])?["values"]
                    .flatMap { ($0 as? [String: Any])?["title"] as? String } ?? ""
                let running = item["running"] as? Bool ?? false
                // ⚠️ updatedAt 是**毫秒**（实测 1789361786040），当秒用会得到 58000 年后
                let updated = (item["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                // 审批是 waterfall 驱动进来的，snapshot 里没有 —— 必须按 id 保留，
                // 否则「等你批准」那一行和它的按钮会凭空消失。
                let existing = sessions.first { $0.id == id }
                let previousApproval = existing?.approval
                let wasRunning = existing?.isRunning ?? false
                next.append(DSHSession(
                    id: id,
                    title: title.isEmpty ? (existing?.title ?? "未命名会话") : title,
                    isRunning: running,
                    updatedAt: updated,
                    approval: previousApproval
                ))
                // 跑完了 → 推一条通知（标题来自 snapshot，事件流里不带标题）
                if wasRunning, !running {
                    notifyFinished(id: id, title: next.last?.title ?? "会话")
                }
            }
            sessions = next
            for s in next { onSessionEvent?(s) }
            error = nil
            return true
        } catch let error as RPCError {
            self.error = rpcMessage(error)
            return false
        } catch {
            self.error = describe(error)
            return false
        }
    }

    private func rpcMessage(_ error: RPCError) -> String {
        switch error {
        case .http(404, _):
            // session/list 是 0.1.2-alpha.2 才加的；版本更老时明确告诉用户去升级
            return "session/list RPC → HTTP 404（DSH 版本过老，请升级到 0.1.2-rc.1 以上）"
        case .http(401, _), .http(403, _):
            // 别把认证/栅栏问题说成「版本太老」——先确认握手与解锁
            return "拿不到会话列表：HTTP \(error.httpCode)。先确认这台电脑已解锁、握手成功（诊断页看 Cookie 条数）"
        case .http(let code, let body):
            return "HTTP \(code)：\(body.prefix(120))"
        case .server(_, let message): return message
        case .badJSON(let text): return "响应不是 JSON：\(text.prefix(120))"
        case .badEnvelope(let text): return "信封不对：\(text.prefix(120))"
        }
    }

    // MARK: - 事件流

    private static let streamID = "dsh-watch"

    /// 打开 `$events`。断开后自动隔几秒重连；连续失败 2 次退到轮询兜底。
    func startEvents() {
        guard !stopped else { return }
        receiveTask?.cancel()
        reconnectTask?.cancel()
        pollTask?.cancel()
        pingTask?.cancel()
        mode = .stream
        receiveTask = Task { [weak self] in
            await self?.runEventStream()
        }
    }

    func stopEvents() {
        stopped = true
        receiveTask?.cancel()
        reconnectTask?.cancel()
        pollTask?.cancel()
        pingTask?.cancel()
        let cancel: [String: Any] = ["type": "cancel", "streamId": Self.streamID]
        if let data = try? JSONSerialization.data(withJSONObject: cancel),
           let text = String(data: data, encoding: .utf8) {
            ws?.send(URLSessionWebSocketTask.Message.string(text)) { _ in }
        }
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        isEventStreamLive = false
        mode = .down
    }

    private func runEventStream() async {
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: wsBase + "/api/remote.mux") else {
            await fallBackToPolling()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 显式把会话 cookie 附上：取不到时一眼能分清是认证问题还是网络问题
        let cookieHeader = DSHCookies.cookieHeader(for: computer.host)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue(Self.appUA, forHTTPHeaderField: "User-Agent")
        // 栅栏要求 Origin 与 Host 同源；代理会把它改写成 loopback，这里显式给一个
        if let up = probe?.upstreamPort, up > 0 {
            request.setValue("http://127.0.0.1:\(up)", forHTTPHeaderField: "Origin")
        }

        // 同步创建（iOS 13+）：连接错误由 receive() 抛出，走下面的重连分支
        let task = session.webSocketTask(with: request)
        ws = task
        task.resume()

        // 打开 $events
        let open: [String: Any] = [
            "type": "open",
            "streamId": Self.streamID,
            "endpoint": "$events",
            "payload": ["args": [String: Any]()]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: open),
           let text = String(data: data, encoding: .utf8) {
            try? await task.send(.string(text))
        }

        isEventStreamLive = true
        wsFailures = 0
        startKeepAlive(task: task)
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleFrame(text) }
                @unknown default: break
                }
            } catch {
                break
            }
        }
        isEventStreamLive = false
        pingTask?.cancel()
        if !Task.isCancelled {
            // 流断了：重连几次，还不行就退到轮询兜底
            wsFailures += 1
            if wsFailures >= 2 {
                await fallBackToPolling()
            } else {
                await reconnect()
            }
        }
    }

    /// 保活：防 NAT 静默断链（Android 侧用 OkHttp 的 pingInterval 20s 做同一件事）。
    private func startKeepAlive(task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                if Task.isCancelled { return }
                try? await task.send(.string("{\"type\":\"ping\"}"))
            }
        }
    }

    private func reconnect() async {
        guard !stopped else { return }
        try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
        guard !Task.isCancelled, !stopped else { return }
        receiveTask = Task { [weak self] in
            await self?.runEventStream()
        }
    }

    /// 轮询兜底：WS 连不上（或服务端根本没注册 `/api/remote.mux`）时
    /// 每 3 秒拉一次 `session/list`；每 20 tick（约 1 分钟）回试一次 WS，
    /// 这样宿升级后能自动切回流，不用重启 App。
    private func fallBackToPolling() async {
        guard !stopped else { return }
        mode = .poll
        isEventStreamLive = false
        receiveTask?.cancel()
        reconnectTask?.cancel()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                _ = await self?.snapshot()
                tick += 1
                if tick % 20 == 0 {
                    // 回试事件流
                    self?.wsFailures = 0
                    self?.mode = .stream
                    self?.startEvents()
                    return
                }
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              outer["type"] as? String == "item",
              let value = outer["value"] as? [String: Any] else {
            return
        }
        let args = value["args"] as? [Any] ?? []

        switch value["type"] as? String {
        case "ready":
            clientId = (value["clientId"] as? String)?.isEmpty == false ? value["clientId"] as? String : nil

        case "emit":
            let event = value["event"] as? String ?? ""
            handleEmit(event: event, args: args)

        case "waterfall":
            let event = value["event"] as? String ?? ""
            let eventId = value["eventId"] as? String ?? ""
            guard let cid = clientId, !eventId.isEmpty else { return }

            // 审批是唯一值得接管的一类 waterfall：手机上你人不在，
            // agent 卡在审批上就是纯浪费。其余一律立刻表态「不处理，继续」——
            // 不回执会让宿主的 waterfall 一直挂着，把网页那边的审批卡死。
            if event == "approval/request" {
                let request = value["request"] as? [String: Any]
                let ask = ApprovalAsk(
                    clientId: cid,
                    eventId: eventId,
                    toolName: (request?["toolName"] as? String) ?? "",
                    reason: request?["reason"] as? String,
                    agent: request?["agent"] as? String,
                    sessionId: (request?["sessionId"] as? String)
                        ?? (value["sessionId"] as? String)
                        ?? (args.first(where: { ($0 as? String)?.hasPrefix("session-") == true }) as? String)
                )
                let taken = onApproval?(ask) ?? false
                if !taken { replyOutcome(clientId: cid, eventId: eventId, outcome: ["kind": "next"]) }
            } else {
                replyOutcome(clientId: cid, eventId: eventId, outcome: ["kind": "next"])
            }

        default:
            break
        }
    }

    private func handleEmit(event: String, args: [Any]) {
        switch event {
        case "api-session/added":
            guard let raw = args.first as? [String: Any],
                  let id = raw["sessionId"] as? String else { return }
            let title = (raw["projections"] as? [String: Any])?["values"]
                .flatMap { ($0 as? [String: Any])?["title"] as? String } ?? ""
            let running = raw["running"] as? Bool ?? false
            let updated = (raw["updatedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                var s = sessions[idx]
                if !title.isEmpty { s.title = title }
                s.isRunning = running
                s.updatedAt = updated
                sessions[idx] = s
                onSessionEvent?(s)
            } else {
                let s = DSHSession(id: id, title: title.isEmpty ? "新会话" : title, isRunning: running, updatedAt: updated, approval: nil)
                sessions.insert(s, at: 0)
                onSessionEvent?(s)
            }

        case "api-session/status":
            // 只带 (sessionId, running)，没有标题
            guard let id = args.first as? String else { return }
            let running = (args.count > 1 ? args[1] as? Bool : nil) ?? false
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                var s = sessions[idx]
                let wasRunning = s.isRunning
                s.isRunning = running
                s.updatedAt = Date()
                // 跑完了：把还挂着的审批清掉（可能是网页那边答的），通知也一起撤
                if wasRunning, !running {
                    if let ask = s.approval {
                        cancelPendingNotification(eventId: ask.eventId)
                    }
                    s.approval = nil
                }
                sessions[idx] = s
                onSessionEvent?(s)
            }

        case "api-session/removed":
            guard let id = args.first as? String else { return }
            sessions.removeAll { $0.id == id }

        default:
            break
        }
    }

    // MARK: - 回执 / 审批

    /// 回执 waterfall。只有两种合法 outcome：
    /// `{kind:'next'}` 我不处理，链条继续；
    /// `{kind:'result', value:<任意 JSON>}` 我处理了，结果是 value。
    private func replyOutcome(clientId: String, eventId: String, outcome: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.unary(
                "$events/result",
                args: ["clientId": clientId, "eventId": eventId, "outcome": outcome]
            )
        }
    }

    /// 替用户回答一条审批。value 取 `allowed-once` / `rejected`。
    func answerApproval(_ ask: ApprovalAsk, allow: Bool) {
        replyOutcome(
            clientId: ask.clientId,
            eventId: ask.eventId,
            outcome: ["kind": "result", "value": allow ? "allowed-once" : "rejected"]
        )
        cancelPendingNotification(eventId: ask.eventId)
        if let idx = sessions.firstIndex(where: { $0.id == ask.sessionId }) {
            sessions[idx].approval = nil
            onSessionEvent?(sessions[idx])
        }
    }

    /// 原生侧接管了一条审批（界面上要显示「等你批准」）。
    func attachApproval(_ ask: ApprovalAsk) {
        guard let sessionId = ask.sessionId,
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        sessions[idx].approval = ask
        onSessionEvent?(sessions[idx])
    }

    // MARK: - 本地通知

    /// 退到后台时原生接管审批：等待批准的请求推一条带动作的通知。
    ///
    /// ask 本体（含 `clientId`，回执要用）**一并塞进 userInfo** ——
    /// App 被通知拉起来时 `sessions` 还是空的，只靠 eventId 找不到它。
    func notifyPending(ask: ApprovalAsk, session: DSHSession) {
        let content = UNMutableNotificationContent()
        content.title = "DSH Go · 等你批准"
        content.body = "\(ask.displayTitle)｜\(session.title)"
        content.categoryIdentifier = "DSH_APPROVAL"
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        var info: [String: Any] = [
            "eventId": ask.eventId,
            "sessionId": ask.sessionId ?? ""
        ]
        if let data = try? JSONEncoder().encode(ask),
           let json = String(data: data, encoding: .utf8) {
            info["ask"] = json
        }
        content.userInfo = info
        // ★ sound 是 content 的属性，不是 request 的参数
        let request = UNNotificationRequest(
            identifier: Self.notificationID(for: ask.eventId),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 跑完了推一条通知。标题来自 snapshot（事件流里只带 sessionId + running）。
    func notifyFinished(id: String, title: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "DSH Go · 跑完了"
        content.body = title
        content.interruptionLevel = .passive
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "dshgo-done-\(id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 审批已回答（或会话结束）→ 把通知撤掉，别让「等你批准」一直挂在托盘里。
    func cancelPendingNotification(eventId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.notificationID(for: eventId)]
        )
    }

    private static func notificationID(for eventId: String) -> String {
        "dshgo-approval-\(eventId)"
    }

    // MARK: - 工具

    private func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut: return "连接超时"
        case .cannotConnectToHost: return "无法连接 \(computer.activeAddress)"
        case .cannotFindHost: return "找不到主机"
        case .networkConnectionLost: return "连接被断开"
        case .notConnectedToInternet: return "网络不可用"
        case .appTransportSecurityRequiresSecureConnection: return "系统拦截了明文 HTTP 请求"
        default: return "错误 \(urlError.code.rawValue)"
        }
    }
}

/// 握手跳数上限：超过就不再跟，把当前这一跳当成最终响应。
///
/// 为什么需要：上游在 launch token 换 cookie 后回 303，`location` 是相对路径 `/`。
/// 客户端**每一跳都带 cookie**时两跳就完事；万一 cookie 没带上（被拒/丢域），
/// 就会 303 → / → 303 无限循环，把握手挂死。
private final class RedirectCapper: NSObject, URLSessionTaskDelegate {

    let maxHops: Int
    private var hops = 0

    init(maxHops: Int) {
        self.maxHops = maxHops
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        hops += 1
        completionHandler(hops > maxHops ? nil : request)
    }
}
