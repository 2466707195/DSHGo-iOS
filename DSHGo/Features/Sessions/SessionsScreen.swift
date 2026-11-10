import SwiftUI

/// 会话 Tab：来自 DSH 的会话列表 + 等待批准的请求。
///
/// agent 卡在审批上等你点头，就是纯浪费。桌面你在看着，手机上你人在厨房 ——
/// 所以**退到后台时原生会接管那条审批**，通知栏直接给两个按钮：
/// 点「允许」agent 立刻继续；**点按钮不会把 App 拉到前台**。
/// 前台时不接管：页面自己在处理，两边抢答会打架。
struct SessionsScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var filter: SessionFilter = .all

    enum SessionFilter: String, CaseIterable, Hashable {
        case all = "全部"
        case pending = "等你批准"
        case running = "执行中"
        case idle = "空闲"

        func match(_ session: DSHSession) -> Bool {
            switch self {
            case .all: return true
            case .pending: return session.approval != nil
            case .running: return session.isRunning
            case .idle: return !session.isRunning
            }
        }
    }

    var body: some View {
        AuroraScreen(showsBar: false) {
            AppTopBar(title: "会话", subtitle: subtitle) {
                if let computer = model.linkState.computer, computer.isOnline {
                    StatusPill(text: computer.name, color: Aurora.success)
                }
            }
        } content: {
            AuroraScrollView(bottomInset: 24) {
                filterBar
                if model.linkState.isOnline {
                    sessionList
                } else {
                    notConnectedCard
                }
            }
        } bar: {
            EmptyView()
        }
        .onAppear { model.syncSessions() }
    }

    private var subtitle: String {
        guard model.linkState.isOnline else { return "未连接" }
        let pending = model.pendingSessions.count
        if pending > 0 {
            return "\(model.sessions.count) 个会话 · \(pending) 个等你批准"
        }
        return "\(model.sessions.count) 个会话"
    }

    // MARK: 筛选

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(SessionFilter.allCases, id: \.self) { item in
                FilterChip(
                    title: item.rawValue,
                    count: count(for: item),
                    selected: filter == item
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { filter = item }
                }
            }
            Spacer()
        }
    }

    private func count(for filter: SessionFilter) -> Int {
        model.sessions.filter { filter.match($0) }.count
    }

    // MARK: 列表

    private var visibleSessions: [DSHSession] {
        let list = model.sessions.filter { filter.match($0) }
        // 等的越靠前：卡在审批上的排最上面
        return list.sorted { a, b in
            if (a.approval != nil) != (b.approval != nil) { return a.approval != nil }
            return a.updatedAt > b.updatedAt
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if model.sessions.isEmpty {
            SectionCard {
                EmptyStateView(
                    systemIcon: "bubble.left.and.bubble.right",
                    title: "还没有会话",
                    message: "电脑上的 DSH 会话会自动同步到这里。"
                )
            }
        } else if visibleSessions.isEmpty {
            SectionCard {
                EmptyStateView(
                    systemIcon: "line.3.horizontal.decrease.circle",
                    title: "没有符合筛选的会话",
                    message: "换一个筛选条件试试。"
                )
            }
        } else {
            VStack(spacing: AuroraMetrics.cardSpacing) {
                ForEach(visibleSessions) { session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: DSHSession) -> some View {
        SectionCard {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(session.status.color.tint(0.13))
                        .frame(width: 36, height: 36)
                    Image(systemName: session.status.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(session.status.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(AuroraFont.titleSmall)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(1)
                        StatusPill(text: session.status.title, color: session.status.color)
                    }
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Aurora.muted)
                }
                Spacer(minLength: 0)
            }

            if let ask = session.approval {
                Spacer().frame(height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("等待批准：\(ask.displayTitle)")
                        .font(AuroraFont.labelMedium)
                        .foregroundStyle(Aurora.warning)
                    if let reason = ask.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Aurora.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let agent = ask.agent, !agent.isEmpty {
                        Text("agent：\(agent)")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer().frame(height: 10)
                HStack(spacing: 8) {
                    DangerTonalButton(text: "拒绝", systemIcon: "xmark") {
                        model.respond(sessionID: session.id, approved: false)
                    }
                    Spacer(minLength: 4)
                    PrimaryButton(
                        text: "允许",
                        systemIcon: "checkmark",
                        enabled: true,
                        expands: false
                    ) {
                        model.respond(sessionID: session.id, approved: true)
                    }
                    .frame(width: 108)
                }
            }
        }
    }

    // MARK: 未连接

    private var notConnectedCard: some View {
        SectionCard {
            EmptyStateView(
                systemIcon: "desktopcomputer",
                title: "还没连接电脑",
                message: "到「连接」页连上一台电脑，会话就会自动同步到这里。"
            )
        }
    }

    /// 「3 分钟前 / 昨天 / 2 小时前」—— 实例方法，不是静态方法。
    private func relativeTime(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
