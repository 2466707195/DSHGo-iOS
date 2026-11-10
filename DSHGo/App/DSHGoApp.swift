import SwiftUI
import UIKit
import Combine

@main
struct DSHGoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
        }
    }
}

// MARK: - Tab 枚举在 Core/Model/DSHModels.swift：computers / sessions / browser / settings

struct RootView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showUnlock = false

    private var tabItems: [AuroraTabSpec<AppTab>] {
        [
            AuroraTabSpec(id: .computers, title: "连接", icon: "desktopcomputer"),
            AuroraTabSpec(id: .sessions, title: "会话", icon: "bubble.left.and.bubble.right"),
            AuroraTabSpec(id: .browser, title: "DSH", icon: "square.stack.3d.up"),
            AuroraTabSpec(id: .settings, title: "设置", icon: "slider.horizontal.3")
        ]
    }

    var body: some View {
        // 底栏一律交给系统（iOS 18+ 原生 Tab，iOS 26+ 自动 Liquid Glass）。
        // 不要再画自绘胶囊，也不要给 TabView 设任何背景 —— 设了就把玻璃盖掉了。
        AuroraTabHost(selection: $model.selectedTab, items: tabItems) { current in
            // 背景必须放进每个 Tab 的内容**内部**：系统玻璃要有东西可折射。
            ZStack {
                AuroraBackdrop()
                screen(for: current)
            }
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
        // 有会话等你批准时浮一个小胶囊，一眼能看到
        .overlay(alignment: .bottom) {
            if !model.pendingSessions.isEmpty, model.selectedTab != .sessions {
                PendingBanner {
                    model.selectedTab = .sessions
                }
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showUnlock) {
            UnlockSheet()
                .environmentObject(model)
                .presentationDetents([.medium])
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.syncSessions()
            }
        }
        .onChange(of: model.linkState) { state in
            if case .unlockRequired = state {
                showUnlock = true
            }
        }
        // 长按图标的三个快捷菜单
        .onReceive(NotificationCenter.default.publisher(for: .dshShortcutNewSession)) { _ in
            model.selectedTab = .browser
        }
        .onReceive(NotificationCenter.default.publisher(for: .dshShortcutRecent)) { _ in
            model.selectedTab = .sessions
        }
        .onReceive(NotificationCenter.default.publisher(for: .dshShortcutSettings)) { _ in
            model.selectedTab = .settings
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .computers:
            ComputersScreen()
        case .sessions:
            SessionsScreen()
        case .browser:
            BrowserScreen()
        case .settings:
            SettingsScreen()
        }
    }
}

// MARK: - 等待批准浮标

private struct PendingBanner: View {

    @EnvironmentObject private var model: AppModel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                StatusDot(color: Aurora.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("等你批准：\(model.pendingSessions.first?.title ?? "会话")")
                        .font(AuroraFont.labelMedium)
                        .foregroundStyle(Aurora.ink)
                        .lineLimit(1)
                    Text("\(model.pendingSessions.count) 个会话卡在审批上")
                        .font(.system(size: 11))
                        .foregroundStyle(Aurora.inkSoft)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Aurora.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(GlassSurface(shape: Capsule(), highlight: 0.34))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 40)
    }
}

// MARK: - 全局提示

struct ToastOverlay: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack {
            if let toast = model.toast {
                HStack(spacing: 7) {
                    Image(systemName: icon(for: toast.kind))
                        .font(.system(size: 12, weight: .bold))
                    Text(toast.text)
                        .font(AuroraFont.labelMedium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(tint(for: toast.kind))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(GlassSurface(shape: Capsule(), highlight: 0.34))
                .padding(.horizontal, 28)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { model.toast = nil }
                }
            }
            Spacer()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast?.id)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(for kind: Toast.Kind) -> Color {
        switch kind {
        case .info: return Aurora.info
        case .success: return Aurora.success
        case .warning: return Aurora.warning
        case .error: return Aurora.danger
        }
    }
}

extension Notification.Name {
    static let dshOpenSessions = Notification.Name("dshOpenSessions")
}