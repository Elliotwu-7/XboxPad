#if os(iOS)
import SafariServices
#elseif os(macOS)
import AppKit
#endif
import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegularLayout: Bool { hSizeClass == .regular }
    #else
    private var isRegularLayout: Bool { true }
    #endif

    @State private var deviceCode: DeviceCodeInfo?
    @State private var statusText: String = ""
    @State private var errorText: String?
    @State private var isRequesting = false
    @State private var isCheckingICloud = false
    @State private var copiedCode = false
    @State private var pollTask: Task<Void, Never>?
    @State private var safariURL: URL?

    var body: some View {
        ZStack {
            XboxAmbientBackground(intensity: 1.35)

            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    Group {
                        if isRegularLayout {
                            HStack(alignment: .center, spacing: 44) {
                                brandHeroColumn(alignedLeading: true)
                                    .frame(maxWidth: 400, alignment: .leading)
                                loginActionCard
                                    .frame(maxWidth: 440)
                            }
                            .frame(maxWidth: 920)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 40)
                        } else {
                            VStack(spacing: 26) {
                                brandHeroColumn(alignedLeading: false)
                                loginActionCard
                                    .frame(maxWidth: 460)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 32)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
            }
        }
        #if os(iOS)
        .sheet(item: Binding(
            get: { safariURL.map { IdentifiableURL(url: $0) } },
            set: { safariURL = $0?.url }
        )) { wrapped in
            SafariSheetView(url: wrapped.url)
                .ignoresSafeArea()
        }
        #endif
        .onDisappear {
            pollTask?.cancel()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, deviceCode == nil, !isRequesting, !isCheckingICloud {
                tryRestoreFromICloud(manual: false)
            }
        }
    }

    private func brandHeroColumn(alignedLeading: Bool) -> some View {
        VStack(alignment: alignedLeading ? .leading : .center, spacing: 20) {
            XboxBrandEmblem(size: alignedLeading ? 78 : 70)

            VStack(alignment: alignedLeading ? .leading : .center, spacing: 8) {
                HStack(spacing: 10) {
                    Text("XboxPad")
                        .font(.system(size: alignedLeading ? 42 : 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(XboxTheme.appVersionDisplay)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(XboxTheme.emeraldBright)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(XboxTheme.emerald.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(XboxTheme.emerald.opacity(0.32), lineWidth: 1))
                }

                Text("原生超低延迟 Xbox 主机串流 & 云游戏客户端")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(alignedLeading ? .leading : .center)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "cpu",
                    color: XboxTheme.emerald,
                    title: "VideoToolbox 零拷贝硬解",
                    subtitle: "Metal 原生渲染 · 原生 Opus 立体声音频"
                )
                featureRow(
                    icon: "waveform.path",
                    color: Color.purple,
                    title: "四马达原生震动反馈",
                    subtitle: "完整支持 Xbox 握把与 LT/RT 扳机震动"
                )
                featureRow(
                    icon: "network",
                    color: XboxTheme.info,
                    title: "双栈智能穿透与中继",
                    subtitle: "IPv4 / IPv6 自动优选 · 局域网与外网无缝切换"
                )
            }
            .padding(16)
            .xboxCard(cornerRadius: 18, fill: XboxTheme.surfaceMuted)
        }
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            XboxIconBadge(systemName: icon, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loginActionCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(deviceCode == nil ? "连接你的 Xbox 账号" : "完成微软设备授权")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(deviceCode == nil
                     ? "采用微软官方 OAuth2 设备码流程，密码仅在微软官网输入。"
                     : "已自动复制验证码，打开微软授权页粘贴即可完成绑定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let code = deviceCode {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("授权验证码")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Button {
                            XboxPlatform.copyToClipboard(code.userCode)
                            withAnimation { copiedCode = true }
                        } label: {
                            HStack(spacing: 10) {
                                Text(code.userCode)
                                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                                    .tracking(5)
                                    .foregroundStyle(XboxTheme.emeraldBright)
                                Image(systemName: copiedCode ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.title3)
                                    .foregroundStyle(copiedCode ? XboxTheme.emeraldBright : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(XboxTheme.bgDeep.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(XboxTheme.emeraldBorderGradient, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Button {
                            XboxPlatform.copyToClipboard(code.userCode)
                            copiedCode = true
                            if let url = URL(string: code.verificationUri) {
                                #if os(iOS)
                                safariURL = url
                                #elseif os(macOS)
                                NSWorkspace.shared.open(url)
                                #endif
                            }
                        } label: {
                            Label("复制并打开微软授权页", systemImage: "safari.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(XboxPrimaryButtonStyle())

                        Button("取消") {
                            cancelLogin()
                        }
                        .buttonStyle(XboxSecondaryButtonStyle())
                    }

                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(XboxTheme.emerald)
                        Text(statusText.isEmpty ? "等待浏览器完成微软账号授权..." : statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Button {
                        startDeviceCodeLogin()
                    } label: {
                        HStack(spacing: 10) {
                            if isRequesting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "person.badge.key.fill")
                            }
                            Text(isRequesting ? "正在获取登录验证码..." : "使用微软 Xbox 账号登录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(XboxPrimaryButtonStyle())
                    .disabled(isRequesting || isCheckingICloud)

                    Button {
                        tryRestoreFromICloud(manual: true)
                    } label: {
                        HStack(spacing: 8) {
                            if isCheckingICloud {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .foregroundStyle(XboxTheme.info)
                            }
                            Text(isCheckingICloud ? "正在检查 iCloud 钥匙串..." : "从 iCloud 钥匙串恢复登录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(XboxSecondaryButtonStyle())
                    .disabled(isRequesting || isCheckingICloud)
                }
            }

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(XboxTheme.warning)
                        .font(.footnote)
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(XboxTheme.warning)
                        .multilineTextAlignment(.leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(XboxTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(XboxTheme.warning.opacity(0.28), lineWidth: 1)
                )
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("xCloud 跨区 IP（可选）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(CloudRegionPreset.presets) { preset in
                        Button(preset.name) {
                            appState.settings.forceRegionIP = preset.ip
                        }
                    }
                } label: {
                    let label = CloudRegionPreset.presets.first(where: { $0.ip == appState.settings.forceRegionIP })?.name ?? "自定义"
                    HStack(spacing: 4) {
                        Text(label)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(XboxTheme.emeraldBright)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(XboxTheme.emerald.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(24)
        .xboxCard(cornerRadius: 22)
    }

    private func tryRestoreFromICloud(manual: Bool) {
        if manual {
            errorText = nil
        }
        isCheckingICloud = true
        Task {
            let restored = await appState.restoreFromICloudKeychain()
            isCheckingICloud = false
            if !restored && manual {
                errorText = "未在 iCloud 钥匙串中找到已同步的 Xbox 登录态（请确认两台设备已开启 iCloud 钥匙串并使用同一 Apple ID 签名安装）。"
            }
        }
    }

    private func startDeviceCodeLogin() {
        errorText = nil
        copiedCode = false
        isRequesting = true
        pollTask?.cancel()

        pollTask = Task {
            do {
                let info = try await appState.authService.requestDeviceCode(
                    forceRegionIP: appState.settings.forceRegionIP
                )
                isRequesting = false
                deviceCode = info
                copiedCode = true
                statusText = "验证码已自动复制，点击按钮打开微软页面粘贴授权"
                XboxPlatform.copyToClipboard(info.userCode)

                _ = try await appState.authService.pollForDeviceCodeToken(
                    info: info,
                    forceRegionIP: appState.settings.forceRegionIP
                )
                safariURL = nil
                statusText = "授权成功，正在换取 Xbox 串流凭证..."
                await appState.completeLogin()
            } catch is CancellationError {
                isRequesting = false
            } catch {
                isRequesting = false
                deviceCode = nil
                errorText = error.localizedDescription
            }
        }
    }

    private func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        deviceCode = nil
        statusText = ""
        copiedCode = false
        isRequesting = false
    }
}

#if os(iOS)
private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SafariSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif
