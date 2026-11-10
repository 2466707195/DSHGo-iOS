import Foundation
import SwiftUI
import Combine
import UIKit
import AVFoundation
import Speech

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var text: String
    var kind: Kind = .info
}

/// 全局状态机：DSH 连接、会话、审批、浏览器、语音。
///
/// 每个连接一条 `DSHTransport`；**当前 + 上一个常驻内存** —— 切过去时滚动位置、
/// 输入框内容都还在，不重新加载。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 连接

    @Published var store = ComputerStore()
    @Published private(set) var activeTransport: DSHTransport?
    @Published private(set) var lastTransport: DSHTransport?
    @Published private(set) var linkState: DSHLinkState = .idle
    @Published var toast: Toast?

    private var transports: [String: DSHTransport] = [:]
    private var bag = Set<AnyCancellable>()
    /// transport 的订阅单独放一个 bag —— 不能跟通知/生命周期订阅混在一起，
    /// 否则每次 connect 的 `removeAll` 会把通知栏动作的订阅也清掉。
    private var transportBag = Set<AnyCancellable>()

    // MARK: - 会话

    @Published private(set) var sessions: [DSHSession] = []

    // MARK: - 浏览器

    @Published var pageTitle: String?
    @Published var currentURL: URL?
    /// DSH 页面是不是正在前台 —— 前台时不接管审批：页面自己在处理，两边抢答会打架。
    @Published var browserActive = false
    @Published var voiceRecording = false
    /// 语音「边说边出字」的中间结果。
    @Published var voiceTranscript = ""

    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()

    init() {
        store.load()

        // 通知栏「允许 / 拒绝」
        NotificationCenter.default.publisher(for: .dshApproveFromNotification)
            .sink { [weak self] note in self?.answerFromNotification(note.userInfo, allow: true) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .dshRejectFromNotification)
            .sink { [weak self] note in self?.answerFromNotification(note.userInfo, allow: false) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onAppForeground() }
            }
            .store(in: &bag)

        // 有上次连接就自动续上
        if let active = store.active {
            connect(computer: active)
        }
    }

    // MARK: - 连接

    func connect(computer: DSHComputer) {
        guard linkState.computer?.id != computer.id else { return }
        deactivateCurrent()

        var updated = computer
        updated.isActive = true
        store.update(updated)
        store.setActive(updated.id)

        linkState = .handshaking(updated)

        let transport = getTransport(for: updated)
        activeTransport = transport
        bind(transport: transport)

        Task {
            await probeAndConnect(transport: transport, computer: updated)
        }
    }

    private func bind(transport: DSHTransport) {
        // transport 的状态变化要冒泡到 AppModel，否则视图收不到更新
        transportBag.removeAll()
        transport.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &transportBag)

        transport.onSessionEvent = { [weak self, weak transport] session in
            guard let self, let transport else { return }
            self.sessions = transport.sessions
        }

        // 审批：DSH 页面在前台就交给页面，否则原生接管
        transport.onApproval = { [weak self, weak transport] ask in
            guard let self, let transport else { return false }
            if self.browserActive { return false }
            // 按 sessionId 挂到对应会话上；事件里没带 sessionId 时兜底挂到第一个
            let target = ask.sessionId ?? self.sessions.first?.id
            var patched = ask
            patched.sessionId = target
            transport.attachApproval(patched)
            if UIApplication.shared.applicationState != .active {
                if let id = target, let session = transport.sessions.first(where: { $0.id == id }) {
                    transport.notifyPending(ask: patched, session: session)
                }
            }
            return true
        }
    }

    /// 通知栏动作：按 eventId 找回审批再回答。
    ///
    /// App 可能是被通知**冷启动**拉起来的 —— 那时 `sessions` 还是空的、
    /// `activeTransport` 还在握手，所以必须能从通知自带的 ask（含 clientId）回答。
    private func answerFromNotification(_ userInfo: [AnyHashable: Any]?, allow: Bool) {
        guard let eventId = userInfo?["eventId"] as? String else { return }

        // 1. 内存里就有（App 活着）
        for session in sessions {
            if let ask = session.approval, ask.eventId == eventId {
                answerApproval(ask, allow: allow)
                return
            }
        }

        // 2. 通知里带的 ask 本体（冷启动）
        if let json = userInfo?["ask"] as? String,
           let data = json.data(using: .utf8),
           let ask = try? JSONDecoder().decode(ApprovalAsk.self, from: data) {
            ensureTransport(for: ask)
            activeTransport?.answerApproval(ask, allow: allow)
            return
        }

        // 3. 连 ask 都没有：至少把通知撤掉，别让它一直挂在托盘里
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["dshgo-approval-\(eventId)"]
        )
    }

    /// 冷启动回答审批前，确保有一条能用的 transport（必要时先把当前连接拉起来）。
    private func ensureTransport(for ask: ApprovalAsk) {
        if activeTransport != nil { return }
        if let computer = store.active {
            connect(computer: computer)
        } else if let sessionId = ask.sessionId {
            if let computer = store.computers.first(where: { $0.id.hasPrefix(sessionId) }) {
                connect(computer: computer)
            }
        }
    }

    private func probeAndConnect(transport: DSHTransport, computer: DSHComputer) async {
        // 1. 原生握手：跟完重定向、收 dsh-auth cookie，并桥接给 WebView
        let handshake = await transport.handshake()
        guard handshake.isOK else {
            var c = computer
            c.isOnline = false
            store.update(c)
            linkState = .failed(c, handshakeFailureMessage(handshake))
            toast = Toast(text: "\(c.name)：\(handshakeFailureMessage(handshake))", kind: .error)
            return
        }

        // 2. 探测：在线 / 延迟 / 插件版本 / 要不要密码
        linkState = .verifying(computer)
        let outcome = await transport.probe()

        switch outcome {
        case .failed(let reason):
            // 多地址自动选路：当前地址连不上才切（Tailscale ↔ 局域网）
            if store.switchAddress(for: computer.id) {
                let switched = store.computers.first { $0.id == computer.id } ?? computer
                toast = Toast(text: "\(reason)，切到 \(switched.displayAddress)", kind: .warning)
                linkState = .handshaking(switched)
                let newTransport = getTransport(for: switched)
                activeTransport = newTransport
                bind(transport: newTransport)
                await probeAndConnect(transport: newTransport, computer: switched)
                return
            }
            var c = computer
            c.isOnline = false
            store.update(c)
            linkState = .failed(c, reason)
            toast = Toast(text: "\(c.name)：\(reason)", kind: .error)
            return

        case .notDshgo:
            var c = computer
            c.isOnline = false
            store.update(c)
            linkState = .failed(c, "这个地址上不是 dshgo")
            toast = Toast(text: "\(c.name) 上不是 dshgo 的转发层", kind: .error)
            return

        case .locked:
            // 在线但被闸门挡着：设了访问密码且本机没有解锁 Cookie
            var c = computer
            c.isOnline = true
            c.needsPassword = true
            store.update(c)
            if c.hasStoredPassword {
                await unlockWithStoredPassword(transport: transport, computer: c)
            } else {
                linkState = .unlockRequired(c)
            }
            return

        case .online(let ms, let version, let needsPassword, _, _):
            var c = computer
            c.isOnline = true
            c.latencyMs = ms
            c.pluginVersion = version
            c.needsPassword = needsPassword
            c.lastSeen = Date()
            store.update(c)

            if needsPassword {
                if c.hasStoredPassword {
                    await unlockWithStoredPassword(transport: transport, computer: c)
                } else {
                    linkState = .unlockRequired(c)
                }
            } else {
                finishConnect(computer: c)
            }
        }
    }

    /// 已存过密码的连接：按当前档位取回来直接解锁（免手输）。
    private func unlockWithStoredPassword(transport: DSHTransport, computer: DSHComputer) async {
        let mode = UnlockPreferences.mode
        // 「每次输密码」这一档本机不存，永远走手动
        guard mode.persistsPassword else {
            linkState = .unlockRequired(computer)
            return
        }
        guard let password = await BiometricUnlock.loadPassword(
            mode: mode,
            account: computer.id,
            reason: BiometricUnlock.reason(for: computer.name)
        ) else {
            // 取不到（Keychain 被清 / 生物识别失败）→ 退回手动
            linkState = .unlockRequired(computer)
            return
        }
        await finishUnlock(transport: transport, computer: computer, password: password)
    }

    private func handshakeFailureMessage(_ result: DSHTransport.HandshakeResult) -> String {
        if case .failed(let message) = result { return message }
        return "握手失败"
    }

    /// 解锁：密码是根凭据，第一次必须先输一次。
    ///
    /// ⚠️ **解锁成功后必须再握手一次。** 设了访问密码时，解锁前那次握手只会拿到
    /// 一张 HTML 密码页（UA 里没有 DSHGo → 走浏览器分支），`dsh-auth-*` cookie
    /// 是过不了闸门的 —— 不重握，紧接着的 `session/list` 就是 401，
    /// 而界面上会错误地显示「DSH 版本太老」。
    private func finishUnlock(transport: DSHTransport, computer: DSHComputer, password: String) async {
        let result = await transport.unlock(password: password)
        switch result {
        case .ok:
            let again = await transport.handshake()
            guard again.isOK else {
                linkState = .failed(computer, "解锁后握手失败：\(handshakeFailureMessage(again))")
                toast = Toast(text: "解锁成功但握手失败，请重试", kind: .error)
                return
            }
            var c = computer
            c.needsPassword = true
            c.isOnline = true
            store.update(c)
            finishConnect(computer: c)
        case .notRequired:
            finishConnect(computer: computer)
        case .badPassword:
            // 密码不对：把 Keychain 里那份也清掉，否则下次会拿旧密码再撞一次
            Keychain.delete(account: computer.id)
            var c = computer
            c.hasStoredPassword = false
            store.update(c)
            linkState = .unlockRequired(c)
            toast = Toast(text: "密码不对，重新输一次", kind: .warning)
        case .failed(let message):
            linkState = .failed(computer, message)
            toast = Toast(text: "解锁失败：\(message)", kind: .error)
        }
    }

    private func finishConnect(computer: DSHComputer) {
        var c = computer
        c.isOnline = true
        store.update(c)

        activeTransport?.startEvents()
        Task { await activeTransport?.snapshot() }
        linkState = .online(c)
        sessions = activeTransport?.sessions ?? []
        toast = Toast(text: "已连接 \(c.name)", kind: .success)
    }

    /// 解锁界面提交的密码。
    func unlock(password: String) {
        guard let computer = linkState.computer,
              let transport = transport(for: computer.id) else {
            return
        }
        // 密码是根凭据：除了「每次输密码」那一档，其它都存 Keychain（不是 UserDefaults）
        let mode = UnlockPreferences.mode
        if mode.persistsPassword {
            Keychain.save(password, account: computer.id)
        }
        var c = computer
        c.hasStoredPassword = mode.persistsPassword
        store.update(c)

        Task {
            await finishUnlock(transport: transport, computer: c, password: password)
        }
    }

    /// 有已存密码时，直接走当前档位的校验取回来解锁（免手输）。
    func unlockWithBiometrics() {
        guard let computer = linkState.computer,
              let transport = transport(for: computer.id) else {
            return
        }
        let mode = UnlockPreferences.mode
        let reason = BiometricUnlock.reason(for: computer.name)
        Task {
            guard let password = await BiometricUnlock.loadPassword(
                mode: mode,
                account: computer.id,
                reason: reason
            ) else {
                toast = Toast(text: "没有取到已存的密码，请手动输一次", kind: .warning)
                return
            }
            await finishUnlock(transport: transport, computer: computer, password: password)
        }
    }

    /// 这台电脑有没有已存的密码（决定解锁界面显示哪个按钮）。
    var hasStoredPassword: Bool {
        guard let computer = linkState.computer else { return false }
        return Keychain.load(account: computer.id) != nil
    }

    /// 用户想换密码：清掉本机存的，重新走解锁界面。
    func forgetPassword() {
        guard let computer = linkState.computer else { return }
        Keychain.delete(account: computer.id)
        var c = computer
        c.hasStoredPassword = false
        store.update(c)
        linkState = .unlockRequired(c)
        toast = Toast(text: "已清除 \(c.name) 的密码", kind: .info)
    }

    func disconnect() {
        deactivateCurrent()
        linkState = .idle
        pageTitle = nil
        currentURL = nil
    }

    private func deactivateCurrent() {
        guard let current = activeTransport else { return }
        current.stopEvents()
        lastTransport = current
        activeTransport = nil
        sessions = []
        var c = current.computer
        c.isActive = false
        store.update(c)
    }

    private func getTransport(for computer: DSHComputer) -> DSHTransport {
        if let existing = transports[computer.id] {
            existing.restart()   // 切回这条连接：重新起事件流
            return existing
        }
        let transport = DSHTransport(computer: computer)
        transports[computer.id] = transport
        return transport
    }

    private func transport(for id: String) -> DSHTransport? {
        transports[id]
    }

    // MARK: - 会话与审批

    var pendingSessions: [DSHSession] {
        sessions.filter { $0.approval != nil }
    }

    /// 页面出现时同步一次（事件流是增量，这里兜底）。
    func syncSessions() {
        guard let transport = activeTransport, linkState.isOnline else { return }
        Task { await transport.snapshot() }
    }

    /// 允许 / 拒绝一条审批。
    func answerApproval(_ ask: ApprovalAsk, allow: Bool) {
        activeTransport?.answerApproval(ask, allow: allow)
        toast = Toast(text: allow ? "已允许" : "已拒绝", kind: allow ? .success : .info)
    }

    func respond(sessionID: String, approved: Bool) {
        guard let ask = sessions.first(where: { $0.id == sessionID })?.approval else { return }
        answerApproval(ask, allow: approved)
    }

    // MARK: - 连接列表探测

    /// 连接列表里那些从没登录过的 DSH 也显示得了状态 —— 打的是
    /// 插件两个不需要先解锁的端点。
    ///
    /// 并发而不是串行：五条连接串行各等 2.5 秒就是 12 秒，列表转半天。
    ///
    /// ⚠️ 探测**不能**走 `getTransport` —— 那个会 `restart()` 起事件流，
    /// 于是列表刷新会给每台电脑（包括离线的）都开一条 WebSocket。
    func refreshAllStatus() async {
        await withTaskGroup(of: Void.self) { group in
            for computer in store.computers {
                group.addTask { @MainActor in
                    // 一次性探测对象：只问端点，不订阅事件流
                    let probeTransport = DSHTransport(computer: computer)
                    let outcome = await probeTransport.probe()
                    var c = computer
                    switch outcome {
                    case .online(let ms, let version, let needsPassword, _, _):
                        c.isOnline = true
                        c.latencyMs = ms
                        c.pluginVersion = version
                        c.needsPassword = needsPassword
                    case .locked:
                        c.isOnline = true
                        c.needsPassword = true
                        c.latencyMs = nil
                    case .notDshgo, .failed:
                        c.isOnline = false
                        c.latencyMs = nil
                    }
                    c.lastSeen = Date()
                    // /info 的 addresses/tailscale 是多地址选路的数据来源：
                    // 用户没手打过 Tailscale 地址时，也能从探测结果里补上
                    if let payload = probeTransport.probe, c.tailscaleHost == nil,
                       let first = payload.tailscale.first ?? payload.addresses.first,
                       let url = URL(string: first), let host = url.host, host != c.host {
                        c.tailscaleHost = host
                        c.tailscalePort = url.port ?? c.port
                    }
                    self.store.update(c)
                }
            }
        }
    }

    // MARK: - 连接增删

    func addComputer(name: String?, address: String, tailscaleAddress: String? = nil) -> DSHComputer? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host else {
            toast = Toast(text: "地址格式不对，例如 http://192.168.1.100:3081", kind: .error)
            return nil
        }
        let port = url.port ?? 3081

        var tsHost: String?
        var tsPort: Int?
        if let raw = tailscaleAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            var tsText = raw
            if !tsText.contains("://") { tsText = "http://" + tsText }
            if let tsURL = URL(string: tsText), let h = tsURL.host {
                tsHost = h
                tsPort = tsURL.port ?? 3081
            }
        }

        let computer = store.add(name: name, host: host, port: port, tailscaleHost: tsHost, tailscalePort: tsPort)
        toast = Toast(text: "已添加 \(computer.name)", kind: .success)
        connect(computer: computer)
        return computer
    }

    func removeComputer(_ computer: DSHComputer) {
        if activeTransport?.computer.id == computer.id {
            disconnect()
        }
        transports.removeValue(forKey: computer.id)
        DSHCookies.clear(forHost: computer.host)
        store.remove(computer)
        toast = Toast(text: "已删除 \(computer.name)", kind: .info)
    }

    // MARK: - 浏览器

    var browserURL: URL? { linkState.computer?.browserURL }

    func reloadBrowser() {
        NotificationCenter.default.post(name: .dshReloadBrowser, object: nil)
    }

    // MARK: - 语音输入

    /// 状态条麦克风按钮：边说边出字。prompt 恰恰适合说 ——
    /// 「把那个登录接口的错误处理改成返回 JSON」，说比打快十倍。
    func toggleVoice() {
        if voiceRecording { stopVoice() } else { startVoice() }
    }

    private func startVoice() {
        Task {
            let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard speechStatus == .authorized else {
                toast = Toast(text: "没有语音识别权限，请在设置里开启", kind: .warning)
                return
            }
            let micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
            guard micGranted else {
                toast = Toast(text: "没有麦克风权限，请在设置里开启", kind: .warning)
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !voiceRecording, let recognizer = speechRecognizer, recognizer.isAvailable else {
            toast = Toast(text: "这台设备不支持中文语音识别", kind: .warning)
            return
        }
        voiceTranscript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionTask?.cancel()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            let node = audioEngine.inputNode
            let format = node.outputFormat(forBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        // 边说边出字：中间结果直接灌进 DSH 的输入框
                        self.voiceTranscript = result.bestTranscription.formattedString
                        NotificationCenter.default.post(
                            name: .dshVoiceInput,
                            object: nil,
                            userInfo: ["text": result.bestTranscription.formattedString, "final": result.isFinal]
                        )
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stopVoice()
                    }
                }
            }
            voiceRecording = true
        } catch {
            stopVoice()
            toast = Toast(text: "启动录音失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func stopVoice() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        voiceRecording = false
    }

    // MARK: - 前台恢复

    private func onAppForeground() {
        guard let transport = activeTransport, linkState.isOnline else { return }
        transport.startEvents()
        sessions = transport.sessions
    }
}

extension Notification.Name {
    static let dshReloadBrowser = Notification.Name("dshReloadBrowser")
    static let dshVoiceInput = Notification.Name("dshVoiceInput")
    static let dshApproveFromNotification = Notification.Name("dshApproveFromNotification")
    static let dshRejectFromNotification = Notification.Name("dshRejectFromNotification")
}
