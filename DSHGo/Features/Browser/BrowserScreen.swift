import SwiftUI
import Combine

/// 浏览器 Tab：`dsh web` 的界面跑在 WebView 里。
///
/// 顶栏显示标题 + 地址，底部工具条给后退/前进/刷新 + 语音输入。
/// 语音「边说边出字」：识别结果实时替换掉输入框里的草稿。
struct BrowserScreen: View {

    @EnvironmentObject private var model: AppModel

    @State private var pageTitle: String?
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var loadFailed = false

    private var computer: DSHComputer? {
        model.linkState.computer
    }

    var body: some View {
        if let computer, computer.isOnline {
            ZStack {
                AuroraBackdrop()
                VStack(spacing: 0) {
                    addressBar(computer)
                    DSHBrowserView(
                        baseURL: computer.browserURL,
                        onTitleChange: { pageTitle = $0 },
                        onURLChange: { currentURL = $0 },
                        onNavStateChange: { back, forward in
                            canGoBack = back
                            canGoForward = forward
                        },
                        onLoadFailed: { _ in loadFailed = true }
                    )
                    .overlay {
                        if loadFailed {
                            VStack(spacing: 0) {
                                EmptyStateView(
                                    systemIcon: "wifi.slash",
                                    title: "页面打不开",
                                    message: "\(computer.displayAddress) 没有响应。确认电脑上 dsh web 在跑，且手机和它在同一网络。"
                                ) {
                                    SmallTonalButton(text: "重试", systemIcon: "arrow.clockwise") {
                                        loadFailed = false
                                        NotificationCenter.default.post(name: .dshReloadBrowser, object: nil)
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .background(Aurora.canvas)
                        }
                    }
                    toolBar
                }
            }
            .onAppear { model.browserActive = true }
            .onDisappear { model.browserActive = false }
        } else {
            AuroraScreen(showsBar: false) {
                AppTopBar(title: "DSH", subtitle: subtitleText)
            } content: {
                AuroraScrollView {
                    EmptyStateView(
                        systemIcon: "square.stack.3d.up",
                        title: notConnectedTitle,
                        message: notConnectedMessage
                    ) {
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
            } bar: {
                EmptyView()
            }
        }
    }

    private var subtitleText: String {
        if let computer {
            return computer.displayAddress
        }
        return model.linkState.title
    }

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

    // MARK: 地址栏

    private func addressBar(_ computer: DSHComputer) -> some View {
        HStack(spacing: 8) {
            GlassIconButton(systemIcon: "chevron.left", tint: canGoBack ? Aurora.ink : Aurora.muted, diameter: 30, iconSize: 12) {
                NotificationCenter.default.post(name: .dshWebBack, object: nil)
            }
            .disabled(!canGoBack)

            VStack(alignment: .leading, spacing: 1) {
                Text(pageTitle ?? "DSH Go")
                    .font(AuroraFont.labelMedium)
                    .foregroundStyle(Aurora.ink)
                    .lineLimit(1)
                Text(currentURL?.absoluteString ?? computer.displayAddress)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Aurora.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassIconButton(systemIcon: "chevron.right", tint: canGoForward ? Aurora.ink : Aurora.muted, diameter: 30, iconSize: 12) {
                NotificationCenter.default.post(name: .dshWebForward, object: nil)
            }
            .disabled(!canGoForward)

            GlassIconButton(systemIcon: "arrow.clockwise", tint: Aurora.ink, diameter: 30, iconSize: 12) {
                NotificationCenter.default.post(name: .dshReloadBrowser, object: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(GlassSurface(shape: Capsule(), highlight: 0.30))
        .padding(.horizontal, AuroraMetrics.pagePadding)
        .padding(.top, 8)
    }

    // MARK: 底部工具条

    private var toolBar: some View {
        GlassBar {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if model.voiceRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Aurora.rose)
                                .frame(width: 8, height: 8)
                            Text("正在听…")
                                .font(AuroraFont.labelMedium)
                                .foregroundStyle(Aurora.rose)
                        }
                        if !model.voiceTranscript.isEmpty {
                            Text(model.voiceTranscript)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Aurora.ink)
                                .lineLimit(2)
                        }
                    } else {
                        Text("点麦克风说话")
                            .font(AuroraFont.labelMedium)
                            .foregroundStyle(Aurora.ink)
                        Text("比如「把登录接口的错误处理改成返回 JSON」")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                GlassIconButton(
                    systemIcon: "mic.fill",
                    tint: model.voiceRecording ? Aurora.rose : Aurora.brand,
                    diameter: 40,
                    iconSize: 16
                ) {
                    model.toggleVoice()
                }
            }
        }
    }
}
