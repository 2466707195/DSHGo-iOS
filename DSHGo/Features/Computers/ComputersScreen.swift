import SwiftUI
import UIKit

/// 首页就是连接列表：多台电脑各存一条，点一下切过去。
///
/// 状态是**探测**出来的 —— 打的是插件两个不需要先解锁的端点
/// （`/__dshgo__/info` + `/__dshgo__/auth/status`），所以列表里那些
/// 从没登录过的 DSH 也显示得了状态。
///
/// **「几个会话在跑」列不出来**：那要先登录它，而列表里的连接
/// 你未必都存过密码 —— 与其显示一个永远空着的「0」，不如不显示。
struct ComputersScreen: View {

    @EnvironmentObject private var model: AppModel
    @State private var showAdd = false
    @State private var isRefreshing = false

    var body: some View {
        AuroraScreen(showsBar: false) {
            AppTopBar(title: "DSH Go", subtitle: "选择要连接的电脑") {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Aurora.brand)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
        } content: {
            AuroraScrollView(bottomInset: 24) {
                // ★ 当前连接的**真实**状态卡：探测得到的「在线」只说明端口通，
                // 真正连没连上看这里（握手/校验/失败原因）。
                if let active = model.store.active {
                    linkStateCard(active)
                }
                if model.store.computers.isEmpty {
                    emptyCard
                } else {
                    VStack(spacing: AuroraMetrics.cardSpacing) {
                        ForEach(model.store.computers) { computer in
                            computerRow(computer)
                        }
                    }
                }
                refreshRow
            }
        } bar: {
            EmptyView()
        }
        .sheet(isPresented: $showAdd) {
            AddComputerSheet()
                .environmentObject(model)
                .presentationDetents([.medium])
        }
        .onAppear {
            Task { await model.refreshAllStatus() }
        }
    }

    // MARK: 真实连接状态

    /// 探测状态 ≠ 连接状态。端口通不代表连上了 —— 握手失败、要解锁、
    /// 会话拉不到，都只体现在 `linkState` 上。这张卡把它明说出来。
    @ViewBuilder
    private func linkStateCard(_ computer: DSHComputer) -> some View {
        let state = model.linkState
        if state.isOnline {
            SectionCard {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Aurora.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已连接 \(computer.name)")
                            .font(AuroraFont.titleSmall)
                            .foregroundStyle(Aurora.ink)
                        Text(model.activeTransport.map { "事件流：\(modeText($0.mode))" } ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.inkSoft)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: state.isConnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(state.isConnecting ? Aurora.info : Aurora.danger)
                        Text(state.isConnecting ? "正在连接…" : "没连上")
                            .font(AuroraFont.titleSmall)
                            .foregroundStyle(Aurora.ink)
                        Spacer(minLength: 0)
                    }

                    // 失败原因 —— 以前只显示 2.6 秒的 toast，用户根本来不及看
                    if case .failed(let c, let reason) = state, c.id == computer.id {
                        Text(reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Aurora.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .unlockRequired = state {
                        Text("这台电脑设了访问密码，需要先解锁。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Aurora.warning)
                    }

                    // 诊断：一眼分清是认证问题还是网络问题
                    if let transport = model.activeTransport {
                        Divider().overlay(Aurora.hairline)
                        infoLine("地址", computer.activeAddress)
                        infoLine("Cookie", transport.lastCookieInfo)
                        infoLine("本机", WiFiInfo.currentIPv4()?.address ?? "未知")
                    }

                    HStack(spacing: 8) {
                        PrimaryButton(
                            text: "重试连接",
                            systemIcon: "arrow.clockwise",
                            enabled: !state.isConnecting,
                            expands: false
                        ) {
                            model.connect(computer: computer)
                        }
                        .frame(width: 128)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func modeText(_ mode: DSHTransport.Mode) -> String {
        switch mode {
        case .stream: return "WebSocket 已连接"
        case .poll: return "轮询兜底"
        case .down: return "已断开"
        }
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 空状态

    private var emptyCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                EmptyStateView(
                    systemIcon: "desktopcomputer",
                    title: "还没有连接",
                    message: "添加一台电脑：打开电脑上 dsh 设置里的「局域网访问」页签，把地址加进来。"
                ) {
                    SmallTonalButton(text: "添加连接", systemIcon: "plus") {
                        showAdd = true
                    }
                }
                Spacer().frame(height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 连接行

    private func computerRow(_ computer: DSHComputer) -> some View {
        Button {
            model.connect(computer: computer)
        } label: {
            HStack(spacing: 10) {
                Monogram(name: computer.name, tone: isActive(computer) ? Aurora.brand : Aurora.muted, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(computer.name)
                            .font(AuroraFont.titleSmall)
                            .foregroundStyle(Aurora.ink)
                            .lineLimit(1)
                        if isActive(computer) {
                            StatusPill(text: "当前", color: Aurora.brand)
                        }
                    }
                    Text(computer.displayAddress)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Aurora.inkSoft)
                        .lineLimit(1)
                    Text(computer.statusText)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(statusColor(computer))
                        .lineLimit(1)                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Aurora.muted)
            }
            .padding(10)
            .background(
                AuroraShape.card.fill(Color.white)
                    .shadow(color: Aurora.cardShadow, radius: 4, y: 1)
            )
            .overlay(
                AuroraShape.card.stroke(
                    isActive(computer) ? Aurora.brand : Aurora.line.opacity(0.55),
                    lineWidth: isActive(computer) ? 1.6 : 1
                )
            )
            .contentShape(AuroraShape.card)
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .contextMenu {
            Button("复制地址") {
                UIPasteboard.general.string = computer.displayAddress
                model.toast = Toast(text: "已复制 \(computer.displayAddress)", kind: .success)
            }
            if let ts = computer.tailscaleHost {
                Button("复制 Tailscale 地址") {
                    UIPasteboard.general.string = "http://\(ts):\(computer.tailscalePort ?? computer.port)"
                    model.toast = Toast(text: "已复制 Tailscale 地址", kind: .success)
                }
            }
            Button("删除", role: .destructive) {
                model.removeComputer(computer)
            }
        }
    }

    private func isActive(_ computer: DSHComputer) -> Bool {
        model.store.active?.id == computer.id
    }

    private func statusColor(_ computer: DSHComputer) -> Color {
        if !computer.isOnline { return Aurora.danger }
        if computer.needsPassword { return Aurora.warning }
        return Aurora.success
    }

    // MARK: 刷新

    private var refreshRow: some View {
        Button {
            isRefreshing = true
            Task {
                await model.refreshAllStatus()
                isRefreshing = false
            }
        } label: {
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView().controlSize(.small).tint(Aurora.brand)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("刷新状态")
                    .font(AuroraFont.labelMedium)
            }
            .foregroundStyle(Aurora.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AuroraShape.card.fill(Color.white))
            .overlay(AuroraShape.card.stroke(Aurora.line.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
    }
}

// MARK: - 添加连接

struct AddComputerSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var tailscale = ""

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                HStack {
                    Text("添加电脑")
                        .font(AuroraFont.titleLarge)
                        .foregroundStyle(Aurora.ink)
                    Spacer()
                    GlassIconButton(systemIcon: "xmark", tint: Aurora.inkSoft, diameter: 30, iconSize: 12) {
                        dismiss()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

                SectionCard {
                    cardTitle("地址")
                    Text("来自电脑 dsh 设置 → 局域网访问，形如 http://192.168.1.100:3081 或 Tailscale 地址 http://100.101.102.103:3081")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    AuroraTextField(
                        placeholder: "http://192.168.1.100:3081",
                        text: $address,
                        systemIcon: "network",
                        keyboardType: .URL
                    )

                    Spacer().frame(height: 12)

                    cardTitle("Tailscale 地址（可选）")
                    Text("家里一套、出门一套。当前地址连不上时自动切过去，不用手动改。")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    AuroraTextField(
                        placeholder: "http://100.101.102.103:3081",
                        text: $tailscale,
                        systemIcon: "point.3.connected.trianglepath.dotted"
                    )

                    Spacer().frame(height: 12)

                    cardTitle("名称（可选）")
                    AuroraTextField(placeholder: "家里电脑 / MacBook Pro / 服务器", text: $name)
                }

                Spacer().frame(height: 12)

                PrimaryButton(text: "连接", systemIcon: "link") {
                    if let _ = model.addComputer(
                        name: name.isEmpty ? nil : name,
                        address: address,
                        tailscaleAddress: tailscale
                    ) {
                        dismiss()
                    }
                }
                .padding(.horizontal, 18)

                Spacer()
            }
        }
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(AuroraFont.titleSmall)
            .foregroundStyle(Aurora.ink)
            .padding(.bottom, 6)
    }
}
