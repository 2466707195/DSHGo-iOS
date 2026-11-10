import SwiftUI
import UIKit

// MARK: - 环形进度

struct RingProgress: View {

    var progress: Double
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Aurora.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Aurora.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Aurora.ink)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 筛选胶囊

struct FilterChip: View {

    let title: String
    var count: Int? = nil
    var selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(AuroraFont.labelMedium)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selected ? Aurora.brand : Aurora.muted)
                }
            }
            // 选中只换字色，底色始终是无色玻璃
            .foregroundStyle(selected ? Aurora.brand : Aurora.inkSoft)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(GlassSurface(shape: Capsule(), shadowRadius: 6, highlight: selected ? 0.40 : 0.26))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
    }
}

// MARK: - 会话状态点

/// 列表里一眼看到「有没有东西在等你批准」：绿点 → 琥珀色。
struct StatusDot: View {

    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: size * 0.5)
                    .frame(width: size * 2, height: size * 2)
            )
    }
}
