import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case gamepad = "手柄与操控"
    case video = "画质与性能"
    case network = "区服与网络"
    case account = "账号与同步"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gamepad: return "gamecontroller.fill"
        case .video: return "sparkles.tv.fill"
        case .network: return "network"
        case .account: return "person.crop.circle.fill"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var gamepadManager: GamepadManager

    let onClose: (() -> Void)?
    @State private var selectedCategory: SettingsCategory
    @State private var showLogoutConfirm = false
    @State private var showCustomIceEditor = false

    init(
        gamepadManager: GamepadManager,
        initialCategory: SettingsCategory = .gamepad,
        onClose: (() -> Void)? = nil
    ) {
        self.gamepadManager = gamepadManager
        self.onClose = onClose
        _selectedCategory = State(initialValue: initialCategory)
    }

    private var isInStreamModal: Bool { onClose != nil }

    var body: some View {
        ZStack {
            XboxAmbientBackground(intensity: 0.9)

            VStack(spacing: 0) {
                headerBar
                categorySegmentedBar
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                ScrollView(showsIndicators: true) {
                    VStack(spacing: 16) {
                        switch selectedCategory {
                        case .gamepad:
                            gamepadStatusCard
                            if gamepadManager.telemetry.connected {
                                gamepadDiagnosticsCard
                            }
                            hapticsCard
                            controlRemappingCard
                            controllerTuningCard
                        case .video:
                            videoCoreCard
                            videoEnhancementCard
                            videoColorGradingCard
                            audioAndSystemCard
                        case .network:
                            networkDoctorCard
                            regionCard
                            networkRelayCard
                        case .account:
                            accountSyncCard
                            aboutCard
                        }
                    }
                    .frame(maxWidth: XboxPlatform.isMac ? 880 : 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, XboxPlatform.isMac ? 26 : 18)
                    .padding(.top, 4)
                    .padding(.bottom, 34)
                }
            }
        }
        .onAppear {
            if !appState.settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showCustomIceEditor = true
            }
        }
        .alert("确定退出当前 Xbox 账号？", isPresented: $showLogoutConfirm) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                Task { await appState.logout() }
            }
        } message: {
            Text(
                XboxPlatform.isMac
                    ? "将清除本机保存的微软登录凭证。"
                    : (appState.settings.iCloudKeychainSync
                       ? "将清除本机及 iCloud 钥匙串中保存的微软登录凭证。"
                       : "将清除本地 Keychain 保存的微软登录凭证。")
            )
        }
    }

    // MARK: - Header & Category Switcher

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("设置与手柄")
                        .font(.system(size: XboxPlatform.isMac ? 30 : (XboxPlatform.isPhone ? 22 : 26), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if isInStreamModal {
                        XboxStatusPill(text: "实时生效", color: XboxTheme.emerald, pulse: true)
                    }
                }
                if isInStreamModal {
                    Text("串流保持运行，画质、震动、摇杆与键鼠调节立即生效")
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let onClose {
                Button {
                    onClose()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.xbCaption.bold())
                        Text("返回画面")
                            .font(.xbSubheadline.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(XboxTheme.emeraldBright, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: XboxPlatform.isMac ? 880 : 780)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, XboxPlatform.isMac ? 26 : 18)
        .padding(.top, isInStreamModal ? 16 : (XboxPlatform.isMac ? 18 : 12))
        .padding(.bottom, 12)
    }

    private var categorySegmentedBar: some View {
        let categories = isInStreamModal
            ? [SettingsCategory.gamepad, .video, .network]
            : SettingsCategory.allCases

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { cat in
                    let active = selectedCategory == cat
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            selectedCategory = cat
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: cat.icon)
                                .font(.xbCaption.weight(.semibold))
                            Text(cat.rawValue)
                                .font(.xbSubheadline.weight(active ? .bold : .medium))
                        }
                        .foregroundStyle(active ? .black : .white.opacity(0.84))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            active
                                ? AnyShapeStyle(XboxTheme.emeraldBright)
                                : AnyShapeStyle(Color.white.opacity(0.08)),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                active ? XboxTheme.emeraldBright.opacity(0.6) : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: XboxPlatform.isMac ? 880 : 780)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 1. Gamepad & Peripherals Tab

    private var gamepadStatusCard: some View {
        let t = gamepadManager.telemetry
        return settingsCard(title: "已连接手柄与外设", icon: "gamecontroller.fill", tint: XboxTheme.emerald) {
            if t.controllers.isEmpty {
                HStack(spacing: 12) {
                    XboxIconBadge(systemName: "gamecontroller", color: .secondary, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("未检测到手柄")
                            .font(.xbHeadline)
                            .foregroundStyle(.white)
                        Text("支持同时接入 1–4 只手柄（Xbox / Elite 2 / PS5 DualSense / Switch Pro 等）")
                            .font(.xbCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(t.controllers) { info in
                        let isSelected = info.playerIndex == t.selectedSlotIndex
                        Button {
                            gamepadManager.selectedSlotIndex = info.playerIndex
                        } label: {
                            HStack(spacing: 12) {
                                XboxIconBadge(
                                    systemName: info.categoryIcon,
                                    color: isSelected ? XboxTheme.emerald : XboxTheme.info,
                                    size: 40
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("P\(info.playerIndex + 1)")
                                            .font(.xbCaption2.bold())
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(isSelected ? XboxTheme.emeraldBright : Color.white.opacity(0.78), in: Capsule())
                                        Text(info.modelName)
                                            .font(.xbSubheadline.weight(.bold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                    }

                                    HStack(spacing: 10) {
                                        Text(info.supportsTriggerRumble ? "四马达震动" : (info.supportsHandleRumble ? "双握把震动" : "无震动马达"))
                                            .font(.xbCaption)
                                            .foregroundStyle(.secondary)
                                        if info.supportsGyro {
                                            Text("含陀螺仪")
                                                .font(.xbCaption)
                                                .foregroundStyle(.cyan)
                                        }
                                        if let pct = info.batteryPercent {
                                            Label("\(pct)%", systemImage: info.isCharging ? "battery.100.bolt" : "battery.75")
                                                .font(.xbCaption.monospacedDigit())
                                                .foregroundStyle(pct <= 20 && !info.isCharging ? XboxTheme.warning : .secondary)
                                        }
                                    }
                                }

                                Spacer()

                                if isSelected {
                                    XboxStatusPill(text: "测试中", color: XboxTheme.emerald, pulse: true)
                                } else {
                                    Text("切换测试")
                                        .font(.xbCaption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(
                                isSelected ? XboxTheme.emerald.opacity(0.11) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isSelected ? XboxTheme.emerald.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if t.keyboardConnected || t.mouseConnected {
                cardDivider
                HStack(spacing: 12) {
                    XboxIconBadge(systemName: "keyboard", color: XboxTheme.info, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已识别外接键盘 / 鼠标")
                            .font(.xbSubheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text([
                            t.keyboardConnected ? "键盘：\(t.keyboardName)" : nil,
                            t.mouseConnected ? "鼠标：\(t.mouseName)" : nil,
                        ].compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.xbCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var gamepadDiagnosticsCard: some View {
        let t = gamepadManager.telemetry
        return settingsCard(title: "摇杆 / 扳机实时监控与四马达震动实测", icon: "waveform.path.ecg", tint: .cyan) {
            HStack(spacing: 20) {
                stickRadar(title: "左摇杆 (LS)", x: t.leftStickX, y: t.leftStickY)
                stickRadar(title: "右摇杆 (RS)", x: t.rightStickX, y: t.rightStickY)

                VStack(alignment: .leading, spacing: 12) {
                    triggerMeter(label: "左扳机 LT", value: t.leftTrigger, color: XboxTheme.emerald)
                    triggerMeter(label: "右扳机 RT", value: t.rightTrigger, color: XboxTheme.info)
                }
                .frame(maxWidth: .infinity)
            }

            cardDivider

            HStack(alignment: .center, spacing: 10) {
                Text("当前按下")
                    .font(.xbCaption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if t.activeButtons.isEmpty {
                    Text("按下手柄任意按键测试响应")
                        .font(.xbCaption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(t.activeButtons, id: \.self) { btn in
                                Text(btn)
                                    .font(.xbCaption.monospaced().bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(XboxTheme.emerald.opacity(0.24), in: Capsule())
                                    .overlay(Capsule().stroke(XboxTheme.emerald.opacity(0.55), lineWidth: 1))
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            cardDivider

            VStack(alignment: .leading, spacing: 10) {
                Text("点击测试独立震动马达")
                    .font(.xbCaption.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ForEach(HapticsEngine.MotorChannel.allCases) { motor in
                        Button {
                            gamepadManager.haptics.testMotor(motor, slotIndex: gamepadManager.selectedSlotIndex)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform.path")
                                    .font(.xbCaption.bold())
                                Text(motor.rawValue)
                                    .font(.xbCaption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(XboxTheme.emeraldBright)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(XboxTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(XboxTheme.emerald.opacity(0.32), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var hapticsCard: some View {
        settingsCard(title: "震动反馈", icon: "waveform.path", tint: .purple) {
            toggleRow(
                title: "启用手柄原生震动",
                subtitle: XboxPlatform.isPhone ? "无手柄时自动使用 iPhone 线性马达模拟震动" : nil,
                icon: "waveform.path",
                color: .purple,
                isOn: $appState.settings.rumbleEnabled
            )

            if appState.settings.rumbleEnabled {
                cardDivider
                sliderRow(
                    title: "握把震动强度",
                    valueText: "\(Int(appState.settings.handleRumbleStrength * 100))%",
                    tint: XboxTheme.emeraldBright,
                    value: $appState.settings.handleRumbleStrength,
                    range: 0.1...1.5,
                    step: 0.05
                )

                cardDivider
                sliderRow(
                    title: "扳机马达强度 (LT / RT)",
                    valueText: "\(Int(appState.settings.triggerRumbleStrength * 100))%",
                    tint: XboxTheme.emeraldBright,
                    value: $appState.settings.triggerRumbleStrength,
                    range: 0.1...1.5,
                    step: 0.05
                )

                cardDivider
                toggleRow(
                    title: "非 Xbox 手柄将扳机震动柔和映射至握把",
                    icon: "arrow.triangle.branch",
                    color: .purple,
                    isOn: $appState.settings.fallbackTriggerToHandles
                )
            }
        }
    }

    private var controlRemappingCard: some View {
        settingsCard(
            title: "操控预设、Elite 背键与键鼠改键",
            icon: "keyboard.badge.ellipsis",
            tint: XboxTheme.emeraldBright,
            footer: "一键切换 FPS / 赛车 / 动作预设；支持 Xbox Elite 2 四个背键与键鼠模拟按键完全自定义。"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("快速游戏预设档案")
                    .font(.xbCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([ControlProfilePreset.standard, .fps, .racing, .souls]) { preset in
                            let active = appState.settings.controlProfile == preset
                            Button {
                                appState.applyControlProfile(preset)
                            } label: {
                                Text(preset.label)
                                    .font(.xbCaption.weight(.semibold))
                                    .foregroundStyle(active ? .black : .white.opacity(0.88))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        active ? AnyShapeStyle(XboxTheme.emeraldBright) : AnyShapeStyle(Color.white.opacity(0.08)),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            cardDivider
            toggleRow(
                title: "扳机 (LT/RT) 与肩键 (LB/RB) 互换",
                icon: "arrow.up.arrow.down.circle",
                color: .orange,
                isOn: $appState.settings.gamepadButtonMap.swapTriggersAndBumpers
            )

            cardDivider
            toggleRow(
                title: "交换左右摇杆 (左撇子布局)",
                icon: "arrow.left.arrow.right",
                color: XboxTheme.info,
                isOn: $appState.settings.gamepadButtonMap.swapSticks
            )

            cardDivider
            HStack(spacing: 12) {
                Toggle("反转左摇杆 Y", isOn: $appState.settings.gamepadButtonMap.invertLeftY)
                    .font(.xbCaption.weight(.medium))
                    .tint(XboxTheme.emerald)
                Toggle("反转右摇杆 Y", isOn: $appState.settings.gamepadButtonMap.invertRightY)
                    .font(.xbCaption.weight(.medium))
                    .tint(XboxTheme.emerald)
            }

            cardDivider
            VStack(alignment: .leading, spacing: 8) {
                Text("Xbox Elite 背键映射 (P1 – P4)")
                    .font(.xbCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                    paddlePickerChip("P1 背键", selection: $appState.settings.gamepadButtonMap.paddle1)
                    paddlePickerChip("P2 背键", selection: $appState.settings.gamepadButtonMap.paddle2)
                    paddlePickerChip("P3 背键", selection: $appState.settings.gamepadButtonMap.paddle3)
                    paddlePickerChip("P4 背键", selection: $appState.settings.gamepadButtonMap.paddle4)
                }
            }

            if appState.settings.keyboardMouseMode == .gamepadEmulation {
                cardDivider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("键鼠模拟自定义键位（WASD 固定移动）")
                            .font(.xbCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重置键位") {
                            appState.settings.keyboardBindingMap = KeyboardBindingMap()
                        }
                        .font(.xbCaption2.weight(.semibold))
                        .foregroundStyle(XboxTheme.emeraldBright)
                        .buttonStyle(.plain)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        keyBindChip("A 键", keyName: $appState.settings.keyboardBindingMap.aKey)
                        keyBindChip("B 键", keyName: $appState.settings.keyboardBindingMap.bKey)
                        keyBindChip("X 键", keyName: $appState.settings.keyboardBindingMap.xKey)
                        keyBindChip("Y 键", keyName: $appState.settings.keyboardBindingMap.yKey)
                        keyBindChip("LB 肩键", keyName: $appState.settings.keyboardBindingMap.lbKey)
                        keyBindChip("RB 肩键", keyName: $appState.settings.keyboardBindingMap.rbKey)
                        keyBindChip("L3 冲刺", keyName: $appState.settings.keyboardBindingMap.l3Key)
                        keyBindChip("R3 近战", keyName: $appState.settings.keyboardBindingMap.r3Key)
                        keyBindChip("View 键", keyName: $appState.settings.keyboardBindingMap.viewKey)
                        keyBindChip("Menu 键", keyName: $appState.settings.keyboardBindingMap.menuKey)
                    }
                }
            }
        }
    }

    private func paddlePickerChip(_ title: String, selection: Binding<PaddleAction>) -> some View {
        HStack {
            Text(title)
                .font(.xbCaption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Menu {
                ForEach(PaddleAction.allCases) { act in
                    Button(act.label) { selection.wrappedValue = act }
                }
            } label: {
                Text(selection.wrappedValue.label)
                    .font(.xbCaption.weight(.semibold))
                    .foregroundStyle(XboxTheme.emeraldBright)
                    .lineLimit(1)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func keyBindChip(_ title: String, keyName: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.xbCaption.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
            Spacer()
            Menu {
                ForEach(KeyboardBindingMap.keyChoices, id: \.self) { key in
                    Button(key) { keyName.wrappedValue = key }
                }
            } label: {
                Text(keyName.wrappedValue)
                    .font(.xbCaption.monospaced().bold())
                    .foregroundStyle(XboxTheme.info)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(XboxTheme.info.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var controllerTuningCard: some View {
        settingsCard(
            title: "摇杆调校、键鼠与快捷键",
            icon: "slider.horizontal.3",
            tint: XboxTheme.info,
            footer: XboxPlatform.isMac
                ? "macOS 快捷键：点击画面锁定 FPS 鼠标 · Esc 解锁 · ⌘F 全屏 · ⌥⌘M 顶栏 · ⇧⌘R 录屏 · ⇧⌘S 截屏 · ⇧⌘V 开麦 · ⇧⌘9 锁定 16:9。"
                : "iPadOS / iOS 26+ 默认将实体西瓜键分配给 Apple Games；前往系统「设置 → 通用 → 游戏手柄 → 主屏幕按钮覆盖」添加 XboxPad 即可直呼 Xbox 菜单。"
        ) {
            sliderRow(
                title: "左摇杆死区 (LS)",
                valueText: String(format: "%.0f%%", appState.settings.leftStickDeadzone * 100),
                tint: XboxTheme.emeraldBright,
                value: $appState.settings.leftStickDeadzone,
                range: 0.0...0.20,
                step: 0.01
            )

            cardDivider
            sliderRow(
                title: "右摇杆死区 (RS)",
                valueText: String(format: "%.0f%%", appState.settings.rightStickDeadzone * 100),
                tint: XboxTheme.emeraldBright,
                value: $appState.settings.rightStickDeadzone,
                range: 0.0...0.20,
                step: 0.01
            )

            cardDivider
            menuPickerRow(
                title: "摇杆响应曲线",
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                color: XboxTheme.emeraldBright,
                currentLabel: appState.settings.stickResponseCurve.label
            ) {
                ForEach(StickResponseCurve.allCases) { curve in
                    Button(curve.label) { appState.settings.stickResponseCurve = curve }
                }
            }

            cardDivider
            sliderRow(
                title: "扳机触发死区 (LT / RT)",
                valueText: String(format: "%.0f%%", appState.settings.triggerDeadzone * 100),
                tint: XboxTheme.info,
                value: $appState.settings.triggerDeadzone,
                range: 0.0...0.25,
                step: 0.01
            )

            cardDivider
            menuPickerRow(
                title: "体感陀螺仪辅助瞄准 (Gyro)",
                icon: "gyroscope",
                color: .cyan,
                currentLabel: appState.settings.gyroAimMode.label
            ) {
                ForEach(GyroAimMode.allCases) { mode in
                    Button(mode.label) { appState.settings.gyroAimMode = mode }
                }
            }

            if appState.settings.gyroAimMode != .off {
                cardDivider
                sliderRow(
                    title: "陀螺仪灵敏度",
                    valueText: String(format: "%.1f×", appState.settings.gyroSensitivity),
                    tint: .cyan,
                    value: $appState.settings.gyroSensitivity,
                    range: 0.2...3.0,
                    step: 0.1
                )

                cardDivider
                toggleRow(
                    title: "反转体感上下视角 (Y 轴)",
                    icon: "arrow.up.arrow.down",
                    color: .cyan,
                    isOn: $appState.settings.gyroInvertY
                )
            }

            cardDivider
            menuPickerRow(
                title: "外接键盘鼠标输入模式",
                icon: "keyboard",
                color: XboxTheme.info,
                currentLabel: appState.settings.keyboardMouseMode.label
            ) {
                ForEach(KeyboardMouseMode.allCases) { mode in
                    Button(mode.label) { appState.settings.keyboardMouseMode = mode }
                }
            }

            if appState.settings.keyboardMouseMode != .off {
                cardDivider
                sliderRow(
                    title: "鼠标视角灵敏度",
                    valueText: String(format: "%.1f×", appState.settings.mouseSensitivity),
                    tint: XboxTheme.info,
                    value: $appState.settings.mouseSensitivity,
                    range: 0.2...3.0,
                    step: 0.1
                )

                if appState.settings.keyboardMouseMode == .gamepadEmulation {
                    Text("模拟键位：WASD 移动 · 鼠标转视角 · 左/右键 RT/LT · 空格 A · C/Ctrl B · R X · E/F Y · Q/G LB/RB · Shift 冲刺 · Tab View · Esc Menu · F12 西瓜键")
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            cardDivider
            menuPickerRow(
                title: "Switch 手柄 A↔B / X↔Y 键位互换",
                subtitle: "Switch Pro / Joy-Con 物理布局自动对齐 Xbox 确认/取消手感",
                icon: "arrow.left.arrow.right.circle.fill",
                color: .red,
                currentLabel: appState.settings.nintendoButtonLayout.label
            ) {
                ForEach(NintendoButtonLayoutMode.allCases) { mode in
                    Button(mode.label) { appState.settings.nintendoButtonLayout = mode }
                }
            }

            cardDivider
            toggleRow(
                title: "麦克风硬件回声消除 (AEC)",
                subtitle: "派对/联机开麦时自动过滤扬声器游戏声，防止队友听到回声",
                icon: "waveform.badge.mic",
                color: XboxTheme.emeraldBright,
                isOn: $appState.settings.micEchoCancellation
            )

            cardDivider
            toggleRow(
                title: "长按 View + Menu 呼出悬浮栏",
                icon: "rectangle.topthird.inset.filled",
                color: .blue,
                isOn: $appState.settings.menuComboEnabled
            )

            cardDivider
            toggleRow(
                title: "Share 键映射为 Xbox 西瓜键",
                icon: "xbox.logo",
                color: XboxTheme.emerald,
                isOn: $appState.settings.mapShareToNexus
            )

            #if os(iOS)
            cardDivider
            toggleRow(
                title: "无手柄时自动显示触控虚拟手柄",
                icon: "hand.tap.fill",
                color: .teal,
                isOn: $appState.settings.showVirtualControlsWhenNoGamepad
            )

            cardDivider
            toggleRow(
                title: "虚拟摇杆随按随出（浮动摇杆）",
                icon: "circle.dashed.inset.filled",
                color: .teal,
                isOn: $appState.settings.virtualGamepadFloatingStick
            )

            cardDivider
            toggleRow(
                title: "虚拟按键 Taptic 轻触反馈",
                icon: "iphone.radiowaves.left.and.right",
                color: .teal,
                isOn: $appState.settings.virtualGamepadHapticTap
            )

            cardDivider
            sliderRow(
                title: "虚拟触控手柄透明度",
                valueText: "\(Int(appState.settings.virtualGamepadOpacity * 100))%",
                tint: .teal,
                value: $appState.settings.virtualGamepadOpacity,
                range: 0.25...0.95,
                step: 0.05
            )

            cardDivider
            sliderRow(
                title: "虚拟按键尺寸缩放",
                valueText: "\(Int((appState.settings.virtualGamepadScale * 100).rounded()))%",
                tint: .teal,
                value: $appState.settings.virtualGamepadScale,
                range: 0.70...1.25,
                step: 0.05
            )

            if !appState.settings.virtualGamepadOffsets.isEmpty {
                cardDivider
                Button {
                    appState.settings.virtualGamepadOffsets = [:]
                    appState.showToast("已恢复默认虚拟手柄按键排版")
                } label: {
                    Text("重置自定义虚拟按键排版")
                        .font(.xbCaption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            #endif

            cardDivider
            Button {
                XboxPlatform.openSystemControllerSettings()
            } label: {
                HStack(spacing: 10) {
                    XboxIconBadge(systemName: "xbox.logo", color: XboxTheme.emeraldBright, size: 30)
                    Text(XboxPlatform.isMac ? "打开系统游戏手柄设置" : "配置物理西瓜键覆盖（关闭 Apple Games）")
                        .font(.xbSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.xbCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 2. Video & Performance Tab

    private var videoCoreCard: some View {
        settingsCard(
            title: "分辨率与低延迟管线",
            icon: "sparkles.tv",
            tint: XboxTheme.emerald,
            footer: "局域网串流推荐「1080p 高码率 HQ」或「2K 1440p」配合「低延迟 80ms」，Xbox 接有线千兆网线可达最佳手感。"
        ) {
            menuPickerRow(
                title: "分辨率与码率模式",
                subtitle: isInStreamModal ? "修改后下次重连生效" : nil,
                icon: "sparkles.tv",
                color: XboxTheme.emerald,
                currentLabel: appState.settings.resolution.label
            ) {
                ForEach(StreamResolution.allCases) { res in
                    Button(res.label) { appState.settings.resolution = res }
                }
            }

            cardDivider
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    XboxIconBadge(systemName: "speedometer", color: .cyan, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("视频码率上限（支持自定义）")
                            .font(.xbSubheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Text(
                            appState.settings.customMaxBitrateMbps == 0
                                ? "自动模式（最高 40 Mbps · 内网自动拉满，弱网自适应）"
                                : "自定义上限 \(appState.settings.customMaxBitrateMbps) Mbps（起播约 \(max(2, appState.settings.customMaxBitrateMbps * 7 / 10))M · 下次重连生效）"
                        )
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(appState.settings.customMaxBitrateMbps == 0 ? "自动" : "\(appState.settings.customMaxBitrateMbps)M")
                        .font(.xbSubheadline.monospacedDigit().bold())
                        .foregroundStyle(.cyan)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach([0, 8, 12, 18, 25, 40, 55], id: \.self) { mbps in
                            let selected = appState.settings.customMaxBitrateMbps == mbps
                            Button {
                                appState.settings.customMaxBitrateMbps = mbps
                            } label: {
                                Text(mbps == 0 ? "自动" : "\(mbps)M")
                                    .font(.xbCaption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(selected ? .black : .white.opacity(0.85))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        selected ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(Color.white.opacity(0.08)),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Text("精细调节")
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(appState.settings.customMaxBitrateMbps == 0 ? 40 : appState.settings.customMaxBitrateMbps) },
                            set: { appState.settings.customMaxBitrateMbps = Int($0.rounded()) }
                        ),
                        in: 4...60,
                        step: 1
                    )
                    .tint(.cyan)
                    Text("4–60M")
                        .font(.xbCaption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            cardDivider
            menuPickerRow(
                title: "低延迟抗抖动档位",
                icon: "gauge.with.needle",
                color: XboxTheme.info,
                currentLabel: appState.settings.latencyProfile.label
            ) {
                ForEach(LatencyProfile.allCases) { profile in
                    Button(profile.label) { appState.settings.latencyProfile = profile }
                }
            }

            cardDivider
            menuPickerRow(
                title: "画面与音频平滑策略",
                icon: "waveform.path.ecg",
                color: XboxTheme.emeraldBright,
                currentLabel: appState.settings.framePacingMode.label
            ) {
                ForEach(VideoFramePacingMode.allCases) { mode in
                    Button(mode.label) { appState.settings.framePacingMode = mode }
                }
            }

            cardDivider
            menuPickerRow(
                title: "画面显示比例",
                icon: "aspectratio",
                color: .indigo,
                currentLabel: appState.settings.aspectMode.label
            ) {
                ForEach(VideoAspectMode.allCases) { mode in
                    Button(mode.label) { appState.settings.aspectMode = mode }
                }
            }

            cardDivider
            sliderRow(
                title: "带鱼屏 / 4:3 黄金比例微缩放",
                valueText: "\(Int((appState.settings.videoZoomScale * 100).rounded()))%",
                tint: .indigo,
                value: $appState.settings.videoZoomScale,
                range: 1.0...1.35,
                step: 0.01
            )

            cardDivider
            toggleRow(
                title: "FPS 中心辅助准星叠层",
                subtitle: "在屏幕几何中心渲染轻量准星，支持 4 种样式",
                icon: "scope",
                color: XboxTheme.emeraldBright,
                isOn: $appState.settings.crosshairEnabled
            )

            if appState.settings.crosshairEnabled {
                cardDivider
                menuPickerRow(
                    title: "准星样式",
                    icon: "plus.viewfinder",
                    color: XboxTheme.emeraldBright,
                    currentLabel: appState.settings.crosshairStyle.label
                ) {
                    ForEach(CrosshairStyle.allCases) { style in
                        Button(style.label) { appState.settings.crosshairStyle = style }
                    }
                }
            }
        }
    }

    private var videoEnhancementCard: some View {
        let headroom = XboxPlatform.potentialEDRHeadroom
        return settingsCard(title: "Metal 原生画质黑科技", icon: "wand.and.stars", tint: .orange) {
            toggleRow(
                title: "120fps 本地 GPU 光流插帧",
                badge: LocalFrameInterpolationSupport.isSupported ? "Metal 就绪" : "不支持",
                badgeColor: LocalFrameInterpolationSupport.isSupported ? XboxTheme.emeraldBright : .secondary,
                icon: "wand.and.stars",
                color: .cyan,
                isOn: $appState.settings.frameInterpolation120Hz
            )
            .disabled(!LocalFrameInterpolationSupport.isSupported)

            cardDivider
            toggleRow(
                title: "Apple MetalFX 硬件空间超分",
                badge: MetalFXSupport.isSupported ? "MetalFX 就绪" : "不支持",
                badgeColor: MetalFXSupport.isSupported ? XboxTheme.emeraldBright : .secondary,
                icon: "wand.and.rays",
                color: XboxTheme.emeraldBright,
                isOn: $appState.settings.metalFXUpscaling
            )
            .disabled(!MetalFXSupport.isSupported)

            cardDivider
            menuPickerRow(
                title: "HDR / EDR 调色增强",
                badge: headroom > 1.05 ? String(format: "EDR %.1f×", headroom) : nil,
                badgeColor: .orange,
                icon: "sun.max.fill",
                color: .orange,
                currentLabel: appState.settings.hdrToneMode.label
            ) {
                ForEach(VideoHDRToneMode.allCases) { mode in
                    Button(mode.label) { appState.settings.hdrToneMode = mode }
                }
            }

            cardDivider
            menuPickerRow(
                title: "CAS 画质锐化增强",
                icon: "camera.filters",
                color: XboxTheme.emeraldBright,
                currentLabel: appState.settings.sharpeningLevel.label
            ) {
                ForEach(VideoSharpeningLevel.allCases) { level in
                    Button(level.label) { appState.settings.sharpeningLevel = level }
                }
            }

            cardDivider
            toggleRow(
                title: "8-bit 暗场去色带 (Debanding)",
                icon: "circle.lefthalf.filled",
                color: .purple,
                isOn: $appState.settings.debandingEnabled
            )
        }
    }

    private var videoColorGradingCard: some View {
        let isDefault = abs(appState.settings.shadowLift) < 0.005
            && abs(appState.settings.videoBrightness) < 0.005
            && abs(appState.settings.videoContrast - 1.0) < 0.005
            && abs(appState.settings.videoSaturation - 1.0) < 0.005

        return settingsCard(
            title: "实时画面调色（Metal GPU 零延迟直出）",
            icon: "slider.horizontal.below.rectangle",
            tint: .pink,
            footer: "串流中打开设置拖动滑块可实时观察变化，尤其适合 FPS 暗处提亮索敌或自定义显示器色彩风格。"
        ) {
            sliderRow(
                title: "暗部提亮 (Shadow Lift)",
                valueText: "+\(Int((appState.settings.shadowLift * 100).rounded()))%",
                tint: .orange,
                value: $appState.settings.shadowLift,
                range: 0.0...0.45,
                step: 0.02
            )

            cardDivider
            sliderRow(
                title: "画面亮度",
                valueText: String(format: "%+.0f%%", appState.settings.videoBrightness * 100),
                tint: .yellow,
                value: $appState.settings.videoBrightness,
                range: -0.25...0.25,
                step: 0.02
            )

            cardDivider
            sliderRow(
                title: "对比度",
                valueText: "\(Int((appState.settings.videoContrast * 100).rounded()))%",
                tint: XboxTheme.info,
                value: $appState.settings.videoContrast,
                range: 0.75...1.35,
                step: 0.02
            )

            cardDivider
            sliderRow(
                title: "色彩饱和度",
                valueText: "\(Int((appState.settings.videoSaturation * 100).rounded()))%",
                tint: .pink,
                value: $appState.settings.videoSaturation,
                range: 0.60...1.45,
                step: 0.02
            )

            if !isDefault {
                cardDivider
                Button {
                    appState.settings.shadowLift = 0.0
                    appState.settings.videoBrightness = 0.0
                    appState.settings.videoContrast = 1.0
                    appState.settings.videoSaturation = 1.0
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("恢复默认画面调色")
                            .font(.xbSubheadline.weight(.semibold))
                    }
                    .foregroundStyle(XboxTheme.emeraldBright)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(XboxTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var audioAndSystemCard: some View {
        settingsCard(title: "音频、投屏与监控", icon: "hifispeaker.2.fill", tint: XboxTheme.info) {
            toggleRow(
                title: "立体声高保真 Opus 音频",
                icon: "hifispeaker.2.fill",
                color: XboxTheme.emerald,
                isOn: $appState.settings.stereoAudio
            )

            cardDivider
            toggleRow(
                title: "显示实时性能监控 HUD",
                icon: "speedometer",
                color: XboxTheme.info,
                isOn: $appState.settings.showPerformanceHUD
            )

            #if os(iOS)
            cardDivider
            toggleRow(
                title: "外接显示器独立 16:9 全屏投屏",
                icon: "airplayvideo",
                color: XboxTheme.info,
                isOn: $appState.settings.externalDisplayFullscreen
            )
            #elseif os(macOS)
            cardDivider
            toggleRow(
                title: "串流窗口锁定 16:9 黄金比例",
                subtitle: "窗口模式下缩放始终保持 16:9 无黑边（快捷键 ⇧⌘9）",
                icon: "macwindow",
                color: XboxTheme.info,
                isOn: $appState.settings.macLock16x9Window
            )
            #endif

            cardDivider
            toggleRow(
                title: "精彩瞬间 30 秒瞬时回放（零编码功耗）",
                subtitle: "内存环形缓存最近 30 秒原始视频帧，随时一键或 ⇧⌘G 导出原画 MP4",
                icon: "clock.arrow.circlepath",
                color: .orange,
                isOn: $appState.settings.instantReplayEnabled
            )

            cardDivider
            toggleRow(
                title: "温控自适应保护（防高热降频）",
                icon: "thermometer.medium",
                color: .orange,
                isOn: $appState.settings.thermalProtectionEnabled
            )

            cardDivider
            toggleRow(
                title: "断流自动重连（最多 5 次）",
                icon: "arrow.triangle.2.circlepath",
                color: XboxTheme.warning,
                isOn: $appState.settings.autoReconnect
            )
        }
    }

    // MARK: - 3. Region & Network Tab

    private var networkDoctorCard: some View {
        let diag = appState.networkDiagnostics
        return settingsCard(
            title: "一键网络体检（NAT / STUN / xCloud 测速）",
            icon: "stethoscope",
            tint: .cyan,
            footer: "通过真实 UDP STUN 探测圆锥/对称 NAT 并测试各大洲 xCloud 网关延迟，给出最优码率与缓冲建议。"
        ) {
            HStack(spacing: 12) {
                XboxIconBadge(systemName: "waveform.path.ecg.rectangle.fill", color: .cyan, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diag.isRunning ? "正在进行 UDP STUN 与网关测速..." : "检测当前网络串流条件")
                        .font(.xbSubheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(diag.report == nil ? "点击右侧按钮立即检测 NAT 类型与最优节点" : diag.report!.natTypeDescription)
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await diag.runDiagnostics() }
                } label: {
                    if diag.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.cyan, in: Capsule())
                    } else {
                        Text(diag.report == nil ? "开始体检" : "重新检测")
                            .font(.xbCaption.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(Color.cyan, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(diag.isRunning)
            }

            if let report = diag.report {
                cardDivider
                HStack(spacing: 10) {
                    if let ms = report.xboxAuthRttMs {
                        diagMetricPill(title: "Xbox 信令", value: "\(ms)ms", good: ms <= 150)
                    }
                    if let addr = report.publicMappedAddress {
                        diagMetricPill(title: "公网映射", value: addr, good: !report.isSymmetricNAT)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(report.regionProbes) { p in
                            let text = p.rttMs.map { "\($0)ms" } ?? "超时"
                            let good = (p.rttMs ?? 999) <= 120
                            diagMetricPill(title: p.name, value: text, good: good)
                        }
                    }
                }

                Text(report.recommendationSummary)
                    .font(.xbCaption)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    appState.settings.resolution = report.recommendedResolution
                    appState.settings.customMaxBitrateMbps = report.recommendedBitrateMbps
                    appState.settings.latencyProfile = report.recommendedLatencyProfile
                    appState.showToast("已应用网络体检推荐参数")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("一键应用推荐配置（\(report.recommendedBitrateMbps == 0 ? "自动40M" : "\(report.recommendedBitrateMbps)M") · \(report.recommendedLatencyProfile.rawValue)ms）")
                            .font(.xbCaption.bold())
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(XboxTheme.emeraldBright, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func diagMetricPill(title: String, value: String, good: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(good ? XboxTheme.emeraldBright : XboxTheme.warning)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.xbCaption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.xbCaption2.monospacedDigit().bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private var regionCard: some View {
        settingsCard(title: "串流区服与云游戏节点", icon: "globe", tint: XboxTheme.info) {
            if !appState.homeRegions.isEmpty {
                menuPickerRow(
                    title: "主机串流信令节点 (xHome)",
                    icon: "tv.and.hifispeaker.fill",
                    color: XboxTheme.emerald,
                    currentLabel: appState.settings.selectedHomeRegion.isEmpty ? "默认推荐节点" : appState.settings.selectedHomeRegion
                ) {
                    Button("默认推荐节点") { appState.settings.selectedHomeRegion = "" }
                    ForEach(appState.homeRegions) { region in
                        Button(region.isDefault ? "\(region.name) (默认)" : region.name) {
                            appState.settings.selectedHomeRegion = region.name
                        }
                    }
                }
                cardDivider
            }

            if !appState.cloudRegions.isEmpty {
                menuPickerRow(
                    title: "云游戏服务器节点 (xCloud)",
                    icon: "cloud.fill",
                    color: XboxTheme.info,
                    currentLabel: appState.settings.selectedCloudRegion.isEmpty ? "默认推荐节点" : appState.settings.selectedCloudRegion
                ) {
                    Button("默认推荐节点") { appState.settings.selectedCloudRegion = "" }
                    ForEach(appState.cloudRegions) { region in
                        Button(region.isDefault ? "\(region.name) (默认)" : region.name) {
                            appState.settings.selectedCloudRegion = region.name
                        }
                    }
                }
                cardDivider
            }

            let regionLabel = CloudRegionPreset.presets.first(where: { $0.ip == appState.settings.forceRegionIP })?.name ?? "自定义"
            menuPickerRow(
                title: "云游戏跨区 IP",
                icon: "globe",
                color: XboxTheme.info,
                currentLabel: regionLabel
            ) {
                ForEach(CloudRegionPreset.presets) { preset in
                    Button(preset.name) { appState.settings.forceRegionIP = preset.ip }
                }
            }

            cardDivider
            Button {
                Task { await appState.refreshAllAfterRegionChange() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                    Text("应用区域修改并重新获取凭证")
                        .font(.xbSubheadline.weight(.semibold))
                }
                .foregroundStyle(XboxTheme.emeraldBright)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(XboxTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(XboxTheme.emerald.opacity(0.32), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var networkRelayCard: some View {
        settingsCard(title: "网络协议与公网穿透", icon: "network", tint: XboxTheme.emerald) {
            menuPickerRow(
                title: "网络协议栈",
                icon: "network",
                color: XboxTheme.emerald,
                currentLabel: appState.settings.networkMode.label
            ) {
                ForEach(NetworkStackMode.allCases) { mode in
                    Button(mode.label) { appState.settings.networkMode = mode }
                }
            }

            if NanoStreamSession.hasBuiltInRelayCluster {
                cardDivider
                toggleRow(
                    title: "默认公网打洞 / 中继加速",
                    subtitle: appState.settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "已启用内置多节点 STUN / TURN 加速集群：优先 P2P 直连，穿透受限时自动中继"
                        : "当前已使用下方自定义服务器覆盖",
                    icon: "bolt.horizontal.circle.fill",
                    color: XboxTheme.warning,
                    isOn: $appState.settings.useBuiltInRelay
                )
            }

            cardDivider
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        showCustomIceEditor.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        XboxIconBadge(systemName: "server.rack", color: XboxTheme.info, size: 30)
                        Text(NanoStreamSession.hasBuiltInRelayCluster ? "覆盖自定义 STUN / TURN 服务器（可选）" : "自定义 STUN / TURN 中继服务器（可选）")
                            .font(.xbSubheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: showCustomIceEditor ? "chevron.up" : "chevron.down")
                            .font(.xbCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showCustomIceEditor {
                    VStack(spacing: 10) {
                        styledInputField(
                            placeholder: "例如 turn:your-server.example:3478（多个用英文逗号分隔）",
                            text: $appState.settings.customIceUrl
                        )
                        if !appState.settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            styledInputField(
                                placeholder: "用户名（纯 STUN 可留空）",
                                text: $appState.settings.customIceUser
                            )
                            styledSecureField(
                                placeholder: "密码 / Credential（纯 STUN 可留空）",
                                text: $appState.settings.customIcePass
                            )
                        }
                        if !NanoStreamSession.hasBuiltInRelayCluster {
                            Text("当前为纯净开源构建，不含内置私有中继服务器。局域网与常规公网默认直连/公开 STUN 打洞；严格 NAT 环境可在此填写自建 coturn / TURN 服务器。")
                                .font(.xbCaption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - 4. Account & Sync Tab

    private var accountSyncCard: some View {
        settingsCard(
            title: "Xbox 账号与跨设备免重登",
            icon: "person.crop.circle.fill",
            tint: XboxTheme.emerald,
            footer: "同一 Wi-Fi 下在 Mac / iPhone / iPad 打开登录页，即可直接发现本设备并端到端加密一键同步；跨网络点上方「复制登录凭证」通过苹果通用剪贴板秒传。"
        ) {
            if !appState.gamertag.isEmpty {
                HStack(spacing: 10) {
                    XboxIconBadge(systemName: "person.crop.circle.fill", color: XboxTheme.emerald, size: 30)
                    Text("当前 Xbox 账号")
                        .font(.xbSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(appState.gamertag)
                        .font(.xbSubheadline.weight(.bold))
                        .foregroundStyle(XboxTheme.emeraldBright)
                }
                cardDivider
            }

            HStack(spacing: 10) {
                XboxIconBadge(systemName: "wave.3.right.circle.fill", color: XboxTheme.emerald, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("局域网近场加密同步")
                        .font(.xbSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text("ECDH + AES-GCM 端到端加密，需核对 6 位码")
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                XboxStatusPill(
                    text: appState.authSyncService.isAdvertising ? "已就绪" : "未启动",
                    color: appState.authSyncService.isAdvertising ? XboxTheme.emerald : .secondary,
                    pulse: appState.authSyncService.isAdvertising
                )
            }

            cardDivider
            Button {
                Task { await appState.exportAuthToUniversalClipboard() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text("复制登录凭证（通用剪贴板同步到其他设备）")
                        .font(.xbSubheadline.weight(.semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(XboxTheme.emeraldBright, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            #if os(iOS)
            cardDivider
            toggleRow(
                title: "iCloud 钥匙串同步登录态",
                subtitle: "同 Apple ID 且同证书签名安装的 iPhone / iPad 可自动同步",
                icon: "icloud.fill",
                color: XboxTheme.info,
                isOn: $appState.settings.iCloudKeychainSync
            )
            #endif
        }
    }

    private var aboutCard: some View {
        settingsCard(
            title: "关于 XboxPad",
            icon: "info.circle.fill",
            tint: .secondary,
            footer: "XboxPad 原生串流引擎 · 底层 WebRTC 协议栈基于 AGPL-3.0 开源项目 XStreaming nano-rs 适配。"
        ) {
            HStack(spacing: 10) {
                XboxIconBadge(systemName: "info.circle.fill", color: .secondary, size: 30)
                Text("当前版本")
                    .font(.xbSubheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("XboxPad \(XboxTheme.appVersionDisplay)")
                    .font(.xbSubheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            cardDivider
            HStack(spacing: 10) {
                XboxIconBadge(
                    systemName: appState.updateChecker.availableUpdate != nil ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath",
                    color: appState.updateChecker.availableUpdate != nil ? XboxTheme.emeraldBright : XboxTheme.info,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        appState.updateChecker.availableUpdate.map { "发现新版本 v\($0.version)" }
                            ?? "软件更新检测"
                    )
                    .font(.xbSubheadline.weight(.medium))
                    .foregroundStyle(.white)
                    if !appState.updateChecker.lastStatusText.isEmpty {
                        Text(appState.updateChecker.lastStatusText)
                            .font(.xbCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.updateChecker.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(XboxTheme.emeraldBright)
                } else if appState.updateChecker.isDownloadingUpdate {
                    HStack(spacing: 6) {
                        ProgressView(value: appState.updateChecker.downloadProgress)
                            .frame(width: 72)
                            .tint(XboxTheme.emeraldBright)
                        Text("\(Int((appState.updateChecker.downloadProgress * 100).rounded()))%")
                            .font(.xbCaption2.monospacedDigit().bold())
                            .foregroundStyle(XboxTheme.emeraldBright)
                    }
                } else if appState.updateChecker.availableUpdate != nil {
                    Button {
                        appState.updateChecker.openUpdateDownload()
                    } label: {
                        Text(XboxPlatform.isMac ? "一键下载更新" : "前往更新")
                            .font(.xbCaption.bold())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(XboxTheme.emeraldBright, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await appState.updateChecker.checkForUpdates(silent: false) }
                    } label: {
                        Text("检查更新")
                            .font(.xbCaption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.9))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isInStreamModal {
                cardDivider
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("退出微软账号")
                            .font(.xbSubheadline.weight(.semibold))
                    }
                    .foregroundStyle(XboxTheme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(XboxTheme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(XboxTheme.danger.opacity(0.32), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Reusable Cross-Platform Card Primitives

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.xbCaption.bold())
                    .foregroundStyle(tint)
                Text(title)
                    .font(.xbCaption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: XboxPlatform.isMac ? 14 : 12) {
                content()
            }
            .padding(XboxPlatform.isMac ? 20 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .xboxCard(cornerRadius: 18)

            if let footer {
                Text(footer)
                    .font(.xbCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private func toggleRow(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        badgeColor: Color = XboxTheme.emeraldBright,
        icon: String,
        color: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 11) {
            XboxIconBadge(systemName: icon, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.xbSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                    if let badge {
                        Text(badge)
                            .font(.xbCaption2.weight(.semibold))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.15), in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(XboxTheme.emerald)
        }
    }

    private func menuPickerRow<MenuContent: View>(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        badgeColor: Color = .orange,
        icon: String,
        color: Color,
        currentLabel: String,
        @ViewBuilder menuItems: () -> MenuContent
    ) -> some View {
        HStack(spacing: 11) {
            XboxIconBadge(systemName: icon, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.xbSubheadline.weight(.medium))
                        .foregroundStyle(.white)
                    if let badge {
                        Text(badge)
                            .font(.xbCaption2.weight(.semibold))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.16), in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.xbCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Menu {
                menuItems()
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .font(.xbCaption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.xbCaption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
        }
    }

    private func sliderRow(
        title: String,
        valueText: String,
        tint: Color,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.xbSubheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(valueText)
                    .font(.xbSubheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            Slider(value: value, in: range, step: step)
                .tint(tint)
        }
    }

    private func styledInputField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .xboxNoAutocapitalization()
            .autocorrectionDisabled()
            .font(.xbSubheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }

    private func styledSecureField(placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.xbSubheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }

    private func stickRadar(title: String, x: Float, y: Float) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.36))
                    .frame(width: 68, height: 68)
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: 68, height: 68)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 56, height: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 56)
                Circle()
                    .fill(XboxTheme.emeraldBright)
                    .shadow(color: XboxTheme.emerald.opacity(0.65), radius: 5)
                    .frame(width: 11, height: 11)
                    .offset(x: CGFloat(x) * 24, y: CGFloat(-y) * 24)
            }
            Text(title)
                .font(.xbCaption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func triggerMeter(label: String, value: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.xbCaption.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.xbCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(max(0, min(1, value)))))
                }
            }
            .frame(height: 8)
        }
    }
}
