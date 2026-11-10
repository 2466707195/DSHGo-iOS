import SwiftUI

/// 原生解锁界面：第一次必须先输密码（密码是根凭据），之后才是指纹/人脸/设备密码。
///
/// 插件侧的边界在 `POST /__dshgo__/unlock`：浏览器看到密码页，App 看到 JSON 401。
/// **两类客户端要的是同一个密码**，`User-Agent` 只决定"用什么界面输"。
struct UnlockSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isUnlocking = false

    private var computer: DSHComputer? {
        model.linkState.computer
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                HStack {
                    Text("解锁")
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
                    VStack(spacing: 12) {
                        Monogram(name: computer?.name ?? "DSH", tone: Aurora.brand, size: 48)
                        Text(computer?.name ?? "这台电脑")
                            .font(AuroraFont.titleMedium)
                            .foregroundStyle(Aurora.ink)
                        Text(computer?.displayAddress ?? "")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Aurora.muted)

                        Spacer().frame(height: 4)

                        AuroraTextField(
                            placeholder: "访问密码",
                            text: $password,
                            systemIcon: "key.fill",
                            isSecure: true
                        )

                        PrimaryButton(text: isUnlocking ? "正在解锁…" : "解锁", systemIcon: "lock.open.fill") {
                            isUnlocking = true
                            model.unlock(password: password)
                            // 解锁成功后 sheet 由 linkState 变化自动收起
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                isUnlocking = false
                            }
                        }
                        .disabled(password.isEmpty || isUnlocking)

                        Text("密码是根凭据：第一次必须先输一次，之后才是指纹或人脸。")
                            .font(.system(size: 11))
                            .foregroundStyle(Aurora.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)

                Spacer()
            }
        }
        .onChange(of: model.linkState) { state in
            if state.isOnline || state == .idle { dismiss() }
        }
    }
}
