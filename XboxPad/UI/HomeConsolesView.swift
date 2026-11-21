import SwiftUI

struct HomeConsolesView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var gamepadManager: GamepadManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isRegularLayout: Bool { hSizeClass == .regular }
    #else
    private var isRegularLayout: Bool { true }
    #endif

    private var columns: [GridItem] {
        if isRegularLayout {
            return [GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 18)]
        }
        return [GridItem(.flexible(), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                XboxAmbientBackground(intensity: 1.0)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        statusDashboardHeader

                        sectionHeader(
                            title: "我的主机",
                            subtitle: appState.consoles.isEmpty ? nil : "\(appState.consoles.count) 台"
                        )

                        if appState.isLoadingConsoles && appState.consoles.isEmpty {
                            loadingCard
                        } else if let err = appState.consoleError, appState.consoles.isEmpty {
                            errorCard(err)
                        } else if appState.consoles.isEmpty {
                            emptyCard
                        } else {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(appState.consoles) { console in
                                    consoleCard(console)
                                }
                            }
                        }

                        minimalFooterTip
                    }
                    .padding(.horizontal, isRegularLayout ? 24 : 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await appState.refreshConsoles()
                }
            }
            .navigationTitle("主机串流")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await appState.refreshConsoles() }
                    } label: {
                        if appState.isLoadingConsoles {
                            ProgressView()
                                .tint(XboxTheme.emerald)
                        } else {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Compact Controller & Spec Header

    private var statusDashboardHeader: some View {
        let t = gamepadManager.telemetry
        let primary = t.controllers.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                XboxIconBadge(
                    systemName: primary?.categoryIcon ?? (t.connected ? "gamecontroller.fill" : "gamecontroller"),
                    color: t.connected ? XboxTheme.emerald : Color.secondary,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(headerDeviceTitle(t))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if t.connected {
                            XboxStatusPill(
                                text: t.controllers.count > 1 ? "\(t.controllers.count)P 联机" : "已就绪",
                                color: XboxTheme.emerald,
                                pulse: true
                            )
                        }
                    }

                    if !t.connected {
                        Text("蓝牙配对或 USB-C 直连手柄 / 键鼠")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if t.controllers.count == 1, let c = primary {
                        HStack(spacing: 8) {
                            Text(c.supportsTriggerRumble ? "四马达震动" : (c.supportsHandleRumble ? "双握把震动" : "标准输入"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let pct = c.batteryPercent {
                                Label("\(pct)%", systemImage: c.isCharging ? "battery.100.bolt" : "battery.75")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(pct <= 20 && !c.isCharging ? XboxTheme.warning : .secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                if !appState.gamertag.isEmpty {
                    gamertagChip
                }
            }

            if t.controllers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(t.controllers) { c in
                            HStack(spacing: 5) {
                                Text("P\(c.playerIndex + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(XboxTheme.emeraldBright, in: Capsule())
                                Text(c.shortModelName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white)
                                if let pct = c.batteryPercent {
                                    Text("\(pct)%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickSpecChip(icon: "sparkles.tv", text: shortResolutionName(appState.settings.resolution))
                    if appState.settings.frameInterpolation120Hz {
                        quickSpecChip(icon: "wand.and.stars", text: "120Hz", tint: .cyan)
                    }
                    if appState.settings.hdrToneMode != .off {
                        quickSpecChip(icon: "sun.max.fill", text: appState.settings.hdrToneMode.shortLabel, tint: .orange)
                    }
                    quickSpecChip(icon: "gauge.with.needle", text: "\(appState.settings.latencyProfile.rawValue)ms")
                    if t.keyboardConnected || t.mouseConnected {
                        let kmText = (t.keyboardConnected && t.mouseConnected)
                            ? "键鼠已连"
                            : (t.keyboardConnected ? "键盘已连" : "鼠标已连")
                        quickSpecChip(icon: "keyboard", text: kmText, tint: XboxTheme.info)
                    }
                }
            }
        }
        .padding(16)
        .xboxCard(cornerRadius: 20, highlighted: t.connected)
    }

    private func headerDeviceTitle(_ t: GamepadTelemetry) -> String {
        if t.controllers.count > 1 {
            return "已连接 \(t.controllers.count) 个手柄"
        }
        if let first = t.controllers.first {
            return first.modelName
        }
        if t.keyboardConnected || t.mouseConnected {
            return "外接键鼠已就绪"
        }
        return "未连接手柄"
    }

    private var gamertagChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(XboxTheme.emeraldBright)
            Text(appState.gamertag)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(XboxTheme.emerald.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(XboxTheme.emerald.opacity(0.28), lineWidth: 1))
    }

    private func quickSpecChip(icon: String, text: String, tint: Color = .white.opacity(0.75)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.8))
    }

    private func sectionHeader(title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Clean Console Cards

    private func consoleCard(_ console: XboxConsole) -> some View {
        let statusColor: Color = console.isOnline ? XboxTheme.emerald : (console.isStandby ? XboxTheme.warning : .gray)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(statusColor.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(statusColor.opacity(0.32), lineWidth: 1)
                        )
                    Image(systemName: "xbox.logo")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(console.deviceName)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(console.friendlyConsoleType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                XboxStatusPill(
                    text: console.isOnline ? "在线" : (console.isStandby ? "待机" : console.powerDisplayText),
                    color: statusColor,
                    pulse: console.isOnline
                )
            }

            HStack(spacing: 10) {
                Button {
                    if console.isStandby {
                        Task { await appState.wakeConsole(console, thenStream: true) }
                    } else {
                        appState.activeStreamTarget = .home(console)
                    }
                } label: {
                    Label(console.isStandby ? "唤醒并串流" : "开始串流", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(XboxPrimaryButtonStyle())

                Menu {
                    Button {
                        Task { await appState.wakeConsole(console, thenStream: false) }
                    } label: {
                        Label("仅远程开机", systemImage: "power")
                    }
                    Button {
                        appState.activeStreamTarget = .home(console)
                    } label: {
                        Label("直接强制连接", systemImage: "bolt.horizontal.fill")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await appState.powerOffConsole(console) }
                    } label: {
                        Label("远程关机", systemImage: "moon.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 46)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
            }
        }
        .padding(18)
        .xboxCard(cornerRadius: 20, highlighted: console.isOnline)
    }

    // MARK: - States & Minimal Footer

    private var loadingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(XboxTheme.emerald)
            Text("正在扫描主机...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .xboxCard(cornerRadius: 20, fill: XboxTheme.surfaceMuted)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            XboxIconBadge(systemName: "exclamationmark.triangle.fill", color: XboxTheme.warning, size: 48)
            Text("获取主机列表失败")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("重新扫描") {
                Task { await appState.refreshConsoles() }
            }
            .buttonStyle(XboxPrimaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .xboxCard(cornerRadius: 20, fill: XboxTheme.surfaceMuted)
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            XboxIconBadge(systemName: "xbox.logo", color: .secondary, size: 50)
            Text("未发现可串流主机")
                .font(.headline)
                .foregroundStyle(.white)
            Text("请在 Xbox 设置 → 远程功能 中开启远程游玩并将电源设为睡眠。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("重新检测") {
                Task { await appState.refreshConsoles() }
            }
            .buttonStyle(XboxSecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .xboxCard(cornerRadius: 20, fill: XboxTheme.surfaceMuted)
    }

    private var minimalFooterTip: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
                .font(.caption2)
                .foregroundStyle(XboxTheme.emeraldBright.opacity(0.8))
            Text("串流时轻触屏幕顶部或长按 View + Menu 呼出控制栏")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    private func shortResolutionName(_ res: StreamResolution) -> String {
        switch res {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1080HQ: return "1440p HQ"
        }
    }
}
