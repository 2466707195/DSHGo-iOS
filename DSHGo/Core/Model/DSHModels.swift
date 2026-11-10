import Foundation
import SwiftUI

// MARK: - 连接（一台电脑）

/// 一条连接 = 一台电脑上的 dshgo 转发端口。
///
/// 多地址自动选路：家里局域网、出门 Tailscale 都记着；
/// 当前地址能用就不动，连不上才切。
struct DSHComputer: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var host: String
    var port: Int
    /// Tailscale 地址（100.64.0.0/10 段）。探测到就用它，连不上再回退局域网。
    var tailscaleHost: String?
    var tailscalePort: Int?
    var lastSeen: Date
    var pluginVersion: String?
    var isOnline: Bool
    var needsPassword: Bool
    var latencyMs: Int?
    /// 本机是否已存访问密码。**只存这一个标记** —— 密码本身在 Keychain，
    /// 永远不要写进 UserDefaults / Codable 模型里。
    var hasStoredPassword: Bool = false
    var isActive: Bool = false

    var displayAddress: String {
        "http://\(host):\(port)"
    }

    /// WebView 加载的入口地址 = 插件转发端口。
    /// 插件服务端会把 Host/Origin 改写成 127.0.0.1:<dshPort> 再转给 dsh web。
    var browserURL: URL {
        URL(string: displayAddress) ?? URL(string: "http://127.0.0.1:3081")!
    }

    /// 当前在用的地址。`host`/`port` 就是「现在连的这个」，
    /// `tailscaleHost`/`tailscalePort` 是**备用的那个** ——
    /// 当前地址能用就不动，连不上才由 `ComputerStore.switchAddress` 互换。
    var activeAddress: String {
        displayAddress
    }

    var statusText: String {
        if !isOnline { return "连不上 —— 不在同一网络？" }
        if needsPassword { return "需要解锁" }
        var parts: [String] = []
        if let ms = latencyMs { parts.append("\(ms) ms") }
        if let version = pluginVersion { parts.append(version) }
        return parts.isEmpty ? "在线" : parts.joined(separator: " · ")
    }
}

// MARK: - 会话

/// 一条等待批准的请求（来自 `approval/request` waterfall 帧）。
///
/// 字段名来自服务端：request 带 `{agent, toolName, callId?, reason?, signal?}`。
/// Android 端卡在审批上就是纯浪费 —— 手机上你人不在，所以原生侧接管它。
struct ApprovalAsk: Identifiable, Hashable, Codable {
    /// 事件流上的 clientId（回执要用）。
    let clientId: String
    /// waterfall 帧的 eventId（回执要用）。
    let eventId: String
    var toolName: String
    var reason: String?
    var agent: String?
    var sessionId: String?
    var askedAt: Date = Date()

    var displayTitle: String {
        toolName.isEmpty ? "操作" : toolName
    }
}

/// DSH 会话。
///
/// 标题来自 `session/list` 的 `projections.values.title`；事件流里
/// `api-session/status` 只带 `(sessionId, running)`，**没有标题** ——
/// 所以启动时要先拉一次全量，之后靠 `api-session/added` 增量补。
struct DSHSession: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var isRunning: Bool
    var updatedAt: Date
    /// 卡在审批上（原生侧接管时非空）。
    var approval: ApprovalAsk?

    /// 等待批准 / 正在执行 / 空闲。
    var status: SessionStatus {
        if approval != nil { return .pending }
        return isRunning ? .running : .idle
    }
}

enum SessionStatus: String, Codable, Hashable {
    case pending    // 等待批准
    case running    // 正在执行
    case idle       // 空闲（跑完了或还没开始）

    var title: String {
        switch self {
        case .pending: return "等待批准"
        case .running: return "正在执行"
        case .idle: return "空闲"
        }
    }

    var color: Color {
        switch self {
        case .pending: return Aurora.warning
        case .running: return Aurora.info
        case .idle: return Aurora.muted
        }
    }

    var icon: String {
        switch self {
        case .pending: return "clock.fill"
        case .running: return "ellipsis.circle.fill"
        case .idle: return "circle"
        }
    }
}

// MARK: - 连接状态机

enum DSHLinkState: Equatable {
    case idle
    case handshaking(DSHComputer)
    case verifying(DSHComputer)
    case online(DSHComputer)
    case unlockRequired(DSHComputer)
    case failed(DSHComputer, String)

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    var computer: DSHComputer? {
        switch self {
        case .handshaking(let c), .verifying(let c), .online(let c), .unlockRequired(let c), .failed(let c, _):
            return c
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .idle: return "未连接"
        case .handshaking(let c): return "正在握手 \(c.name)"
        case .verifying(let c): return "正在校验 \(c.name)"
        case .online(let c): return "已连接 \(c.name)"
        case .unlockRequired(let c): return "\(c.name) 需要解锁"
        case .failed(let c, let reason): return "\(c.name)：\(reason)"
        }
    }
}

// MARK: - Tab

enum AppTab: Hashable {
    case computers
    case sessions
    case browser
    case settings
}
