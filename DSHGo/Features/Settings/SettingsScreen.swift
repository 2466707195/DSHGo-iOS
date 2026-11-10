import SwiftUI
import UIKit

/// 设置：当前连接（含局域网访问信息）、解锁方式、界面布局、安全边界、诊断、关于。
struct SettingsScreen: View {

    @EnvironmentObject private var model: AppModel
    @State private var showForgetConfirm = false
    @State private var layout = UserDefaults.standard.string(forKey: "dshgo.layout") ?? "mobile"

    private let layoutOptions: [(id: String, title: String)] = [
        ("auto", "自动"),
        ("mobile", "手机布局"),
        ("desktop", "电脑布局")
    ]

    var body: some View {
        AuroraScreen(showsBar: false) {
            AppTopBar(title: "设置", subtitle: "连接、解锁与安全")
        } content: {
            AuroraScrollView(bottomInset: 24) {
                currentConnectionCard
                lanAccessCard
                layoutCard
                unlockCard
                securityCard
                diagnosticsCard
                aboutCard
            }
        } bar: {
            EmptyView()
        }
        .alert("清除这台电脑的密码？", isPresented: $showForgetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { model.forgetPassword() }
        } message: {
            Text("下次连接这台电脑时需要重新输入一次访问密码。")
        }
    }

    // MARK: 当前连接

    private var currentConnectionCard: some View {
        SectionCard {
            cardTitle("当前连接")

            if let computer = model.linkState.computer {
                infoRow("电脑", computer.name)
                infoRow("地址", computer.displayAddress)
                if let version = computer.pluginVersion {
                    infoRow("插件版本", version)
                }
                if let latency = computer.latencyMs {
                    infoRow("延迟", "\(latency) ms")
                }
                infoRow("状态", model.linkState.title)
                infoRow("事件流", model.activeTransport.map { modeText($0.mode) } ?? "未连接")

                Spacer().frame(height: 10)
                HStack(spacing: 8) {
                    SmallTonalButton(text: "复制地址", systemIcon: "doc.on.doc") {
                        UIPasteboard.general.string = computer.displayAddress
                        model.toast = Toast(text: "已复制地址", kind: .success)
                    }
                    SmallTonalButton(text: "重新连接", systemIcon: "arrow.clockwise") {
                        model.connect(computer: computer)
                    }
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notConnectedTitle)
                        .font(AuroraFont.titleSmall)
                        .foregroundStyle(Aurora.ink)
                    Text(notConnectedMessage)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let computer = model.store.active {
                            SmallTonalButton(text: "重试连接", systemIcon: "arrow.clockwise") {
                                model.connect(computer: computer)
                            }
                        }
                        SmallTonalButton(text: "去连接页", systemIcon: "rectangle.grid.1x2") {
                            model.selectedTab = .computers
                        }
                    }
                }
            }
        }
    }

    // MARK: 局域网访问（对应插件设置页签）

    private var lanAccessCard: some View {
        SectionCard {
            cardTitle("局域网访问")

            Text("电脑上 dsh 设置 →「局域网访问」页签里有本机所有可用地址和二维码，扫一下就能把地址加进来。")
                .font(.system(size: 11.5))
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 10)

            if let computer = model.linkState.computer {
                addressRow(computer.displayAddress, isTailscale: false)
                if let ts = computer.tailscaleHost {
                    addressRow("http://\(ts):\(computer.tailscalePort ?? computer.port)", isTailscale: true)
                }
                Spacer().frame(height: 6)
            }

            bullet("network", "转发端口默认对同网络的所有设备开放 —— 装上就能用，但也意味着同一 Wi-Fi 下任何人都能打开它。")
            bullet("lock.shield", "需要多一层就加访问密码：浏览器输密码，App 走指纹或面部。")
            bullet("globe", "需要公网访问用 Tailscale（100.64.0.0/10），别把端口转发到公网。")
        }
    }

    private func addressRow(_ address: String, isTailscale: Bool) -> some View {
        Button {
            UIPasteboard.general.string = address
            model.toast = Toast(text: "已复制 \(address)", kind: .success)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isTailscale ? "point.3.connected.trianglepath.dotted" : "wifi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isTailscale ? Aurora.teal : Aurora.inkSoft)
                    .frame(width: 18)
                Text(address)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Aurora.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Aurora.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 界面布局

    private var layoutCard: some View {
        SectionCard {
            cardTitle("界面布局")
            Text("DSH 自己按视口宽度判定抽屉/电脑布局，且只在启动时判一次。这里在页面脚本执行前覆盖那一次判定。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                ForEach(layoutOptions, id: \.id) { option in
                    FilterChip(
                        title: option.title,
                        selected: layout == option.id
                    ) {
                        layout = option.id
                        UserDefaults.standard.set(option.id, forKey: "dshgo.layout")
                        model.toast = Toast(text: "已切换为\(option.title)，刷新页面后生效", kind: .info)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: 解锁

    private var unlockCard: some View {
        SectionCard {
            cardTitle("解锁方式")

            // 档位选择
            VStack(alignment: .leading, spacing: 6) {
                ForEach(UnlockMode.allCases) { mode in
                    Button {
                        UnlockPreferences.mode = mode
                        model.toast = Toast(text: "解锁方式：\(mode.title)", kind: .info)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: UnlockPreferences.mode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(UnlockPreferences.mode == mode ? Aurora.brand : Aurora.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.title)
                                    .font(AuroraFont.bodyMedium)
                                    .foregroundStyle(Aurora.ink)
                                Text(mode.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Aurora.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)

            Divider().overlay(Aurora.hairline).padding(.vertical, 6)

            infoRow("已存密码", model.hasStoredPassword ? "已存（Keychain）" : "未存")

            if model.linkState.computer != nil {
                Spacer().frame(height: 8)
                HStack(spacing: 8) {
                    SmallTonalButton(text: "清除密码", systemIcon: "key.slash") {
                        showForgetConfirm = true
                    }
                    .disabled(!model.hasStoredPassword)
                    Spacer()
                }
            }

            Spacer().frame(height: 8)
            bullet("faceid", "密码存在系统 Keychain（不参与 iCloud 备份），不是 UserDefaults 明文。")
            bullet("hand.raised", "最严的一档是「每次输密码」：本机不存密码，每次都要打。")
        }
    }

    // MARK: 安全

    private var securityCard: some View {
        SectionCard {
            cardTitle("安全边界")
            bullet("key.fill", "插件把入站请求的 Host/Origin 统一改写成 127.0.0.1:<dshPort> 再转发 —— 栅栏永远看到 loopback。")
            bullet("lock.doc.fill", "密码用 scrypt 加盐存在电脑侧；改密码会同时轮换签名密钥，所有已解锁设备立刻失效。")
            bullet("exclamationmark.triangle.fill", "它把能执行任意代码的 DSH 暴露到了局域网：只在可信网络里开，别转发端口到公网。")
        }
    }

    // MARK: 诊断

    private var diagnosticsCard: some View {
        SectionCard {
            cardTitle("诊断")
            infoRow("连接状态", model.linkState.title)
            if let transport = model.activeTransport {
                infoRow("事件流", modeText(transport.mode))
                infoRow("Cookie", transport.lastCookieInfo)
                if let error = transport.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.danger)
                        .padding(.top, 4)
                }
            }
            infoRow("本机 IPv4", WiFiInfo.currentIPv4()?.address ?? "未获取")

            Text("拿不到会话列表时：确认电脑上的 dsh web 已重启（插件只在启动时挂载），且 DSH 版本 ≥ 0.1.2-rc.1（session/list 与 /api/remote.mux 都是 0.1.2-rc.1 才有的）。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        SectionCard {
            cardTitle("关于")
            infoRow("应用", "DSH Go（iOS）")
            infoRow("版本", "0.1.0（1）")
            infoRow("对应", "github.com/xiazhi88/dshgo")
            Text("独立第三方客户端，按 dshgo 的 Android 版功能与协议（android/docs/PROTOCOL.md）复刻。")
                .font(.system(size: 11))
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    // MARK: 小组件

    /// 未连接的真正原因 —— 别再一律显示「未连接」。
    private var notConnectedTitle: String {
        if case .failed = model.linkState { return "连接失败" }
        if case .unlockRequired = model.linkState { return "需要解锁" }
        if model.linkState.isConnecting { return "正在连接…" }
        if model.store.computers.isEmpty { return "还没有添加电脑" }
        return "还没连接电脑"
    }

    private var notConnectedMessage: String {
        if case .failed(_, let reason) = model.linkState { return reason }
        if case .unlockRequired = model.linkState { return "这台电脑设了访问密码，回连接页输一次。" }
        if model.store.computers.isEmpty {
            return "到「连接」页添加一台电脑：打开电脑上 dsh 设置里的「局域网访问」页签，把地址加进来。"
        }
        return "到「连接」页点一下那台电脑。"
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(AuroraFont.titleMedium)
            .foregroundStyle(Aurora.ink)
            .padding(.bottom, 6)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Aurora.teal)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Aurora.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Aurora.muted)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Aurora.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    /// 事件流三种模式：流 / 轮询兜底 / 断了。
    private func modeText(_ mode: DSHTransport.Mode) -> String {
        switch mode {
        case .stream: return "WebSocket 事件流"
        case .poll: return "轮询兜底（每 3 秒，每分钟回试一次事件流）"
        case .down: return "已断开"
        }
    }
}
