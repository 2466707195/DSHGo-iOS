import SwiftUI

// === Aurora UI · Tab 页容器（iOS / SwiftUI）===
//
// **底栏不自绘，一律交给系统。**
//   · iOS 18+   → 原生 `TabView` + `Tab`
//   · iOS 26+   → 同一份代码，系统自动给 Liquid Glass（悬浮胶囊、折射、边缘高光、滚动联动）
//   · iOS 16/17 → 同一个 `TabView`，标签用 `.tabItem`（系统经典底栏）
//
// 为什么 2026-11 把自绘底栏整段删掉（别再写回去）：
//   1. Liquid Glass 是系统级材质：折射、边缘高光、随内容滚动变形、和安全区/键盘联动。
//      自己铺一层 `.ultraThinMaterial` 只能得到「一层发灰的磨砂片」，永远对不上真机效果，
//      而且在深色模式、放大字号、降低透明度等辅助功能下全都不会跟随。
//   2. iOS 26 的底栏还带 `tabBarMinimizeBehavior(_:)`（滚动收起）、
//      `tabViewBottomAccessory(_:)`（Apple Music 式常驻条）、用户自定义排序
//      （`.tabViewCustomization(_:)`）—— 这些能力全长在系统控件上，自绘版本一个都拿不到。
//   3. 自绘底栏必须自己处理安全区、键盘、点击穿透、拖动手势与点按手势分流，
//      每上一个系统大版本都要重新调一遍。收益只有「视觉上像自家设计」，成本远高于收益。
//
// 代价（唯一一条）：`Tab` 不是 `View`，条件性角标做不到。
//   详见 references/ios-components.md 的 1.3 节；真需要动态角标就走 UIKit
//   `UITabBarController` + `tabBarItem.badgeValue`。
//
// **选中态必须无色**：`.tint(Aurora.ink)`（近黑），不要 `Aurora.brand`，也不要留系统默认蓝。
//   底栏是全屏唯一「不该抢注意力」的控件，彩色选中项会和内容里的品牌元素打架。
//
// 用法见 references/ios-components.md 第 1 节。

// MARK: - 共享 spec

/// Tab 项描述。`Value` 通常是业务枚举。
struct AuroraTabSpec<Value: Hashable>: Identifiable {

    let id: Value
    let title: String

    /// 图标。**必须用 outline 变体**（`house` 而不是 `house.fill`）——
    /// 系统会自动把选中态换成 filled，这里再给 filled 会导致选中/未选中一模一样。
    let icon: String

    init(id: Value, title: String, icon: String) {
        self.id = id
        self.title = title
        self.icon = icon
    }

    /// 兼容旧调用：早期自绘底栏需要单独指定选中图标。
    ///
    /// 现在底栏由系统绘制，系统会自动换 filled 变体，`selectedIcon` 不再有任何作用。
    @available(*, deprecated, message: "原生 TabView 自动把 outline 换成 filled，selectedIcon 已无用；改用 init(id:title:icon:)")
    init(id: Value, title: String, icon: String, selectedIcon: String?, badge: String? = nil) {
        self.init(id: id, title: title, icon: icon)
    }
}

// MARK: - Tab 页宿主

/// Tab 页宿主：内部就是一块原生 `TabView`，iOS 26 上自动获得 Liquid Glass。
///
/// ```swift
/// AuroraTabHost(selection: $tab, items: [
///     AuroraTabSpec(id: AppTab.home, title: "首页", icon: "house"),
///     AuroraTabSpec(id: AppTab.drive, title: "网盘", icon: "folder"),
/// ]) { tab in
///     switch tab { case .home: HomeView() ... }
/// }
/// ```
///
/// **不要在它外面再包 ZStack 画背景**：把背景（`AuroraBackdrop()`）放进 `content` 里，
/// 让每个 Tab 自己铺满。这样系统玻璃才有东西可折射，滚动时也不会透出白底。
struct AuroraTabHost<Value: Hashable, Content: View>: View {

    @Binding private var selection: Value
    private let items: [AuroraTabSpec<Value>]
    private let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [AuroraTabSpec<Value>],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._selection = selection
        self.items = items
        self.content = content
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            modernTabView
        } else {
            legacyTabView
        }
    }

    // MARK: iOS 18+ / 26：原生 Tab

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Tab(value: item.id, role: nil) {
                    content(item.id)
                } label: {
                    // 用 Label 而不是 Tab("标题", systemImage:)：
                    // 后者的首参是字面量友好的签名，传 String 变量不稳
                    Label(item.title, systemImage: item.icon)
                }
            }
        }
        // 选中态**不许有彩色**：用近黑 ink，不是 brand。
        // 不设的话系统默认给蓝色 tint，和 Aurora 的靛蓝主色撞在一起更难看。
        // 玻璃底色由系统决定，别去覆盖。
        .tint(Aurora.ink)
    }

    // MARK: iOS 16/17：同一个 TabView，用 .tabItem

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                content(item.id)
                    .tabItem { Label(item.title, systemImage: item.icon) }
                    .tag(item.id)
            }
        }
        .tint(Aurora.ink)
    }
}

// MARK: - 旧名兼容

/// 早期叫 `AuroraTabView`（只有 iOS 18 分支），现在统一走 `AuroraTabHost`。
typealias AuroraTabView<Value: Hashable, Content: View> = AuroraTabHost<Value, Content>

/// 最早叫 `AuroraLegacyTabBar`（自绘胶囊）。自绘版本已删除，这里只是把老调用点接住。
///
/// ⚠️ 名字里的 legacy 已经不代表「自绘」——它现在就是原生 `TabView`。
@available(*, deprecated, message: "自绘底栏已移除，改用 AuroraTabHost（内部就是原生 TabView + Tab）")
typealias AuroraLegacyTabBar<Value: Hashable, Content: View> = AuroraTabHost<Value, Content>

// MARK: - iOS 26 可选增强（按需打开，默认不动）

// TabView(selection:) { ... }
//     .tabBarMinimizeBehavior(.onScrollDown)        // 往下滚时把底栏收成小胶囊
//     .tabViewBottomAccessory { MiniPlayerView() }  // 底栏上方的常驻条（26.1+）
//
// 两者都是纯系统行为，不需要任何自绘。`tabBarMinimizeBehavior` 会让内容可视区域变高，
// 如果页面里有「吸底按钮」要跟着动，先别开。
