import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var gamepadManager: GamepadManager
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                XboxAmbientBackground(intensity: 0.85)

                Form {
                    gamepadTestSection
                    streamQualitySection
                    hapticsSettingsSection
                    controllerSettingsSection
                    regionAndNetworkSection
                    accountSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置与手柄")
            .alert("确定退出当前 Xbox 账号？", isPresented: $showLogoutConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出登录", role: .destructive) {
                    Task { await appState.logout() }
                }
            } message: {
                Text(appState.settings.iCloudKeychainSync
                     ? "将清除本机及 iCloud 钥匙串中保存的微软登录凭证。"
                     : "将清除本地 Keychain 保存的微软登录凭证。")
            }
        }
    }

    // MARK: - Live Gamepad & 4-Motor Rumble Diagnostics

    private var gamepadTestSection: some View {
        let t = gamepadManager.telemetry
        return Section {
            if t.controllers.isEmpty {
                HStack(spacing: 12) {
                    XboxIconBadge(systemName: "gamecontroller", color: .secondary, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未检测到手柄")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("支持同时连接 1–4 个手柄（Xbox / DualSense / Switch Pro 等）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(XboxTheme.surface)
            } else {
                ForEach(t.controllers) { info in
                    let isSelected = info.playerIndex == t.selectedSlotIndex
                    Button {
                        gamepadManager.selectedSlotIndex = info.playerIndex
                    } label: {
                        HStack(spacing: 12) {
                            XboxIconBadge(
                                systemName: info.categoryIcon,
                                color: isSelected ? XboxTheme.emerald : XboxTheme.info,
                                size: 38
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("P\(info.playerIndex + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isSelected ? XboxTheme.emeraldBright : Color.white.opacity(0.75), in: Capsule())
                                    Text(info.modelName)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                HStack(spacing: 8) {
                                    Text(info.supportsTriggerRumble ? "四马达" : (info.supportsHandleRumble ? "双握把" : "无马达"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if info.supportsGyro {
                                        Text("陀螺仪")
                                            .font(.caption)
                                            .foregroundStyle(.cyan)
                                    }
                                    if let pct = info.batteryPercent {
                                        Label("\(pct)%", systemImage: info.isCharging ? "battery.100.bolt" : "battery.75")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(pct <= 20 && !info.isCharging ? XboxTheme.warning : .secondary)
                                    }
                                }
                            }

                            Spacer()

                            if isSelected {
                                XboxStatusPill(text: "测试中", color: XboxTheme.emerald, pulse: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(XboxTheme.surface)
                }
            }

            if t.keyboardConnected || t.mouseConnected {
                HStack(spacing: 10) {
                    XboxIconBadge(systemName: "keyboard", color: XboxTheme.info, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已识别外接键鼠")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text([
                            t.keyboardConnected ? "键盘：\(t.keyboardName)" : nil,
                            t.mouseConnected ? "鼠标：\(t.mouseName)" : nil,
                        ].compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(XboxTheme.surface)
            }

            if t.connected {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        stickRadar(title: "左摇杆 (LS)", x: t.leftStickX, y: t.leftStickY)
                        stickRadar(title: "右摇杆 (RS)", x: t.rightStickX, y: t.rightStickY)

                        VStack(alignment: .leading, spacing: 10) {
                            triggerMeter(label: "LT", value: t.leftTrigger, color: XboxTheme.emerald)
                            triggerMeter(label: "RT", value: t.rightTrigger, color: XboxTheme.info)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前触发按键")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if t.activeButtons.isEmpty {
                            Text("按下任意按键测试输入响应")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(t.activeButtons, id: \.self) { btn in
                                        Text(btn)
                                            .font(.caption.monospaced().bold())
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(XboxTheme.emerald.opacity(0.24), in: Capsule())
                                            .overlay(Capsule().stroke(XboxTheme.emerald.opacity(0.55), lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(XboxTheme.surface)

                VStack(alignment: .leading, spacing: 10) {
                    Text("独立马达震动测试")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(HapticsEngine.MotorChannel.allCases) { motor in
                            Button {
                                gamepadManager.haptics.testMotor(motor)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform.path")
                                        .font(.caption.bold())
                                    Text(motor.rawValue)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(XboxTheme.emeraldBright)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(XboxTheme.emerald.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(XboxTheme.emerald.opacity(0.30), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(XboxTheme.surface)
            }
        } header: {
            Text("手柄连接与四马达震动实测")
        }
    }

    private func stickRadar(title: String, x: Float, y: Float) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 66, height: 66)
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .frame(width: 66, height: 66)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 54, height: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 54)
                Circle()
                    .fill(XboxTheme.emeraldBright)
                    .shadow(color: XboxTheme.emerald.opacity(0.65), radius: 5)
                    .frame(width: 11, height: 11)
                    .offset(x: CGFloat(x) * 24, y: CGFloat(-y) * 24)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func triggerMeter(label: String, value: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
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

    // MARK: - Video & Latency Settings

    private var streamQualitySection: some View {
        Section {
            Picker(selection: $appState.settings.resolution) {
                ForEach(StreamResolution.allCases) { res in
                    Text(res.label).tag(res)
                }
            } label: {
                settingLabel("分辨率与码率模式", icon: "sparkles.tv", color: XboxTheme.emerald)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.latencyProfile) {
                ForEach(LatencyProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            } label: {
                settingLabel("低延迟抗抖动档位", icon: "gauge.with.needle", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.framePacingMode) {
                ForEach(VideoFramePacingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingLabel("画面与音频平滑策略", icon: "waveform.path.ecg", color: XboxTheme.emeraldBright)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.frameInterpolation120Hz) {
                HStack(spacing: 8) {
                    settingLabel("120fps 本地 GPU 光流插帧", icon: "wand.and.stars", color: .cyan)
                    Spacer(minLength: 4)
                    Text(LocalFrameInterpolationSupport.isSupported ? "Metal 就绪" : "不支持")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LocalFrameInterpolationSupport.isSupported ? XboxTheme.emeraldBright : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (LocalFrameInterpolationSupport.isSupported ? XboxTheme.emerald : Color.white).opacity(0.14),
                            in: Capsule()
                        )
                }
            }
            .disabled(!LocalFrameInterpolationSupport.isSupported)
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.aspectMode) {
                ForEach(VideoAspectMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingLabel("画面显示比例", icon: "aspectratio", color: Color.indigo)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.sharpeningLevel) {
                ForEach(VideoSharpeningLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            } label: {
                settingLabel("CAS 画质锐化增强", icon: "camera.filters", color: XboxTheme.emeraldBright)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.hdrToneMode) {
                ForEach(VideoHDRToneMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                let headroom = XboxPlatform.potentialEDRHeadroom
                HStack(spacing: 8) {
                    settingLabel("HDR / EDR 调色增强", icon: "sun.max.fill", color: .orange)
                    if headroom > 1.05 {
                        Spacer(minLength: 4)
                        Text(String(format: "EDR %.1f×", headroom))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    }
                }
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.debandingEnabled) {
                settingLabel("8-bit 暗场去色带 (Debanding)", icon: "circle.lefthalf.filled", color: .purple)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.metalFXUpscaling) {
                HStack(spacing: 8) {
                    settingLabel("Apple MetalFX 硬件空间超分", icon: "wand.and.rays", color: XboxTheme.emeraldBright)
                    Spacer(minLength: 4)
                    Text(MetalFXSupport.isSupported ? "MetalFX 就绪" : "不支持")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MetalFXSupport.isSupported ? XboxTheme.emeraldBright : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (MetalFXSupport.isSupported ? XboxTheme.emerald : Color.white).opacity(0.14),
                            in: Capsule()
                        )
                }
            }
            .disabled(!MetalFXSupport.isSupported)
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.externalDisplayFullscreen) {
                settingLabel("外接显示器独立 16:9 全屏投屏", icon: "airplayvideo", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.thermalProtectionEnabled) {
                settingLabel("温控自适应保护（防高热降频）", icon: "thermometer.medium", color: .orange)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.stereoAudio) {
                settingLabel("立体声高保真 Opus 音频", icon: "hifispeaker.2.fill", color: XboxTheme.emerald)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.showPerformanceHUD) {
                settingLabel("显示实时性能监控 HUD", icon: "speedometer", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.autoReconnect) {
                settingLabel("断流自动重连（最多 5 次）", icon: "arrow.triangle.2.circlepath", color: XboxTheme.warning)
            }
            .listRowBackground(XboxTheme.surface)
        } header: {
            Text("串流画质与低延迟引擎")
        } footer: {
            Text("局域网主机串流推荐使用「1080p 高码率 HQ」+「低延迟 80ms」，配合 Xbox 插千兆网线可达最佳手感。")
        }
    }

    // MARK: - Haptics Settings

    private var hapticsSettingsSection: some View {
        Section {
            Toggle(isOn: $appState.settings.rumbleEnabled) {
                settingLabel("启用手柄原生震动", icon: "waveform.path", color: .purple)
            }
            .listRowBackground(XboxTheme.surface)

            if appState.settings.rumbleEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("握把震动强度")
                        Spacer()
                        Text("\(Int(appState.settings.handleRumbleStrength * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(XboxTheme.emeraldBright)
                    }
                    Slider(value: $appState.settings.handleRumbleStrength, in: 0.1...1.5, step: 0.05)
                }
                .listRowBackground(XboxTheme.surface)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("扳机马达强度 (LT / RT)")
                        Spacer()
                        Text("\(Int(appState.settings.triggerRumbleStrength * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(XboxTheme.emeraldBright)
                    }
                    Slider(value: $appState.settings.triggerRumbleStrength, in: 0.1...1.5, step: 0.05)
                }
                .listRowBackground(XboxTheme.surface)

                Toggle("非 Xbox 手柄将扳机震动柔和映射至握把", isOn: $appState.settings.fallbackTriggerToHandles)
                    .listRowBackground(XboxTheme.surface)
            }
        } header: {
            Text("震动反馈")
        }
    }

    // MARK: - Controller Settings

    private var controllerSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("左摇杆死区 (LS)")
                    Spacer()
                    Text(String(format: "%.0f%%", appState.settings.leftStickDeadzone * 100))
                        .monospacedDigit()
                        .foregroundStyle(XboxTheme.emeraldBright)
                }
                Slider(value: $appState.settings.leftStickDeadzone, in: 0.0...0.20, step: 0.01)
            }
            .listRowBackground(XboxTheme.surface)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("右摇杆死区 (RS)")
                    Spacer()
                    Text(String(format: "%.0f%%", appState.settings.rightStickDeadzone * 100))
                        .monospacedDigit()
                        .foregroundStyle(XboxTheme.emeraldBright)
                }
                Slider(value: $appState.settings.rightStickDeadzone, in: 0.0...0.20, step: 0.01)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.stickResponseCurve) {
                ForEach(StickResponseCurve.allCases) { curve in
                    Text(curve.label).tag(curve)
                }
            } label: {
                settingLabel("摇杆响应曲线", icon: "point.topleft.down.to.point.bottomright.curvepath", color: XboxTheme.emeraldBright)
            }
            .listRowBackground(XboxTheme.surface)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("扳机触发死区 (LT / RT)")
                    Spacer()
                    Text(String(format: "%.0f%%", appState.settings.triggerDeadzone * 100))
                        .monospacedDigit()
                        .foregroundStyle(XboxTheme.info)
                }
                Slider(value: $appState.settings.triggerDeadzone, in: 0.0...0.25, step: 0.01)
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.gyroAimMode) {
                ForEach(GyroAimMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingLabel("体感陀螺仪辅助瞄准 (Gyro)", icon: "gyroscope", color: .cyan)
            }
            .listRowBackground(XboxTheme.surface)

            if appState.settings.gyroAimMode != .off {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("陀螺仪灵敏度")
                        Spacer()
                        Text(String(format: "%.1f×", appState.settings.gyroSensitivity))
                            .monospacedDigit()
                            .foregroundStyle(.cyan)
                    }
                    Slider(value: $appState.settings.gyroSensitivity, in: 0.2...3.0, step: 0.1)
                }
                .listRowBackground(XboxTheme.surface)

                Toggle("反转体感上下视角 (Y 轴)", isOn: $appState.settings.gyroInvertY)
                    .listRowBackground(XboxTheme.surface)
            }

            Picker(selection: $appState.settings.keyboardMouseMode) {
                ForEach(KeyboardMouseMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingLabel("外接键盘鼠标输入模式", icon: "keyboard", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            if appState.settings.keyboardMouseMode != .off {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("鼠标视角灵敏度")
                        Spacer()
                        Text(String(format: "%.1f×", appState.settings.mouseSensitivity))
                            .monospacedDigit()
                            .foregroundStyle(XboxTheme.info)
                    }
                    Slider(value: $appState.settings.mouseSensitivity, in: 0.2...3.0, step: 0.1)
                }
                .listRowBackground(XboxTheme.surface)

                if appState.settings.keyboardMouseMode == .gamepadEmulation {
                    Text("模拟键位：WASD 移动 · 鼠标转视角 · 左/右键 RT/LT · 空格 A · C/Ctrl B · R X · E/F Y · Q/G LB/RB · Shift 冲刺 · Tab View · Esc Menu · F12 西瓜键")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(XboxTheme.surface)
                }
            }

            Toggle(isOn: $appState.settings.menuComboEnabled) {
                settingLabel("长按 View + Menu 呼出悬浮栏", icon: "rectangle.topthird.inset.filled", color: .blue)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.mapShareToNexus) {
                settingLabel("Share 键映射为 Xbox 西瓜键", icon: "xbox.logo", color: XboxTheme.emerald)
            }
            .listRowBackground(XboxTheme.surface)

            Toggle(isOn: $appState.settings.showVirtualControlsWhenNoGamepad) {
                settingLabel("无手柄时自动显示触控虚拟手柄", icon: "hand.tap.fill", color: .teal)
            }
            .listRowBackground(XboxTheme.surface)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("虚拟触控手柄透明度")
                    Spacer()
                    Text("\(Int(appState.settings.virtualGamepadOpacity * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.teal)
                }
                Slider(value: $appState.settings.virtualGamepadOpacity, in: 0.25...0.95, step: 0.05)
            }
            .listRowBackground(XboxTheme.surface)
            Button {
                openControllerHomeButtonSettings()
            } label: {
                HStack(spacing: 10) {
                    settingLabel("配置物理西瓜键覆盖（关闭 Apple Games）", icon: "xbox.logo", color: XboxTheme.emeraldBright)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(XboxTheme.surface)
        } header: {
            Text("手柄精细调校与体感瞄准")
        } footer: {
            Text("iPadOS 26/27 默认将物理西瓜键分配给 Apple Games。如需像 OneCast / Midori 一样在串流中直接按西瓜键呼出 Xbox 菜单，请前往 iPad「设置 → 通用 → 游戏手柄 → 主屏幕按钮 → 主屏幕按钮覆盖（Home Button Overrides）」添加 XboxPad（若未立即生效重启一次 iPad 即可）；也可使用 Share 键直传西瓜键。")
        }
    }

    private func openControllerHomeButtonSettings() {
        XboxPlatform.openSystemControllerSettings()
    }

    // MARK: - Region & Network

    private var regionAndNetworkSection: some View {
        Section {
            if !appState.homeRegions.isEmpty {
                Picker("主机串流信令节点 (xHome)", selection: $appState.settings.selectedHomeRegion) {
                    Text("默认推荐节点").tag("")
                    ForEach(appState.homeRegions) { region in
                        Text(region.isDefault ? "\(region.name) (默认)" : region.name).tag(region.name)
                    }
                }
                .listRowBackground(XboxTheme.surface)
            }

            if !appState.cloudRegions.isEmpty {
                Picker("云游戏服务器节点 (xCloud)", selection: $appState.settings.selectedCloudRegion) {
                    Text("默认推荐节点").tag("")
                    ForEach(appState.cloudRegions) { region in
                        Text(region.isDefault ? "\(region.name) (默认)" : region.name).tag(region.name)
                    }
                }
                .listRowBackground(XboxTheme.surface)
            }

            Picker(selection: $appState.settings.forceRegionIP) {
                ForEach(CloudRegionPreset.presets) { preset in
                    Text(preset.name).tag(preset.ip)
                }
            } label: {
                settingLabel("云游戏跨区 IP", icon: "globe", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            Button {
                Task { await appState.refreshAllAfterRegionChange() }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(XboxTheme.emeraldBright)
                    Text("应用区域修改并重新获取凭证")
                        .foregroundStyle(XboxTheme.emeraldBright)
                }
            }
            .listRowBackground(XboxTheme.surface)

            Picker(selection: $appState.settings.networkMode) {
                ForEach(NetworkStackMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                settingLabel("网络协议", icon: "network", color: XboxTheme.emerald)
            }
            .listRowBackground(XboxTheme.surface)

            if NanoStreamSession.hasBuiltInRelayCluster {
                Toggle(isOn: $appState.settings.useBuiltInRelay) {
                    settingLabel("默认公网打洞 / 中继加速", icon: "bolt.horizontal.circle.fill", color: XboxTheme.warning)
                }
                .listRowBackground(XboxTheme.surface)

                if appState.settings.useBuiltInRelay && appState.settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("已启用内置多节点 STUN / TURN 加速集群：优先 P2P 直连，穿透受限时自动就近中继。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(XboxTheme.surface)
                }
            }

            DisclosureGroup(NanoStreamSession.hasBuiltInRelayCluster ? "覆盖自定义 STUN / TURN 服务器（可选）" : "自定义 STUN / TURN 中继服务器（可选）") {
                TextField("例如 turn:your-server.example:3478（逗号分隔多个）", text: $appState.settings.customIceUrl)
                    .xboxNoAutocapitalization()
                    .autocorrectionDisabled()
                if !appState.settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TextField("用户名（纯 STUN 可留空）", text: $appState.settings.customIceUser)
                        .xboxNoAutocapitalization()
                        .autocorrectionDisabled()
                    SecureField("密码 / Credential（纯 STUN 可留空）", text: $appState.settings.customIcePass)
                }
                if !NanoStreamSession.hasBuiltInRelayCluster {
                    Text("当前为纯净开源构建，不含内置私有中继服务器。局域网与常规公网默认直连/公开 STUN 打洞；严格 NAT 环境可在此手动填写自建 coturn / TURN 服务器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(XboxTheme.surface)
        } header: {
            Text("区服与网络")
        }
    }

    // MARK: - Account & About

    private var accountSection: some View {
        Section {
            if !appState.gamertag.isEmpty {
                HStack {
                    settingLabel("当前账号", icon: "person.crop.circle.fill", color: XboxTheme.emerald)
                    Spacer()
                    Text(appState.gamertag)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(XboxTheme.surface)
            }

            Button {
                Task {
                    await appState.exportAuthToUniversalClipboard()
                }
            } label: {
                HStack {
                    settingLabel("复制登录凭证（同步到其他设备）", icon: "doc.on.clipboard.fill", color: XboxTheme.emeraldBright)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(XboxTheme.surface)

            HStack {
                settingLabel("局域网近场同步", icon: "wave.3.right.circle.fill", color: XboxTheme.emerald)
                Spacer()
                Text(appState.authSyncService.isAdvertising ? "已就绪（加密广播中）" : "未启动")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(appState.authSyncService.isAdvertising ? XboxTheme.emeraldBright : .secondary)
            }
            .listRowBackground(XboxTheme.surface)

            Text("同一 Wi-Fi 下在 Mac / iPhone / iPad 打开登录页，可直接发现本设备并端到端加密一键同步登录；跨网络也可点上方「复制登录凭证」通过苹果通用剪贴板秒传。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(XboxTheme.surface)

            #if os(iOS)
            Toggle(isOn: $appState.settings.iCloudKeychainSync) {
                settingLabel("iCloud 钥匙串同步登录态", icon: "icloud.fill", color: XboxTheme.info)
            }
            .listRowBackground(XboxTheme.surface)

            Text("同一 Apple ID 下用相同证书签名安装的 iPhone / iPad 可通过系统 iCloud 钥匙串自动同步登录态。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(XboxTheme.surface)
            #endif

            HStack {
                settingLabel("版本信息", icon: "info.circle.fill", color: .secondary)
                Spacer()
                Text("XboxPad \(XboxTheme.appVersionDisplay)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(XboxTheme.surface)

            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Label("退出微软账号", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            .listRowBackground(XboxTheme.surface)
        } header: {
            Text("账号与关于")
        } footer: {
            Text("XboxPad 原生串流引擎 · 底层 WebRTC 协议栈基于 AGPL-3.0 开源项目 XStreaming nano-rs 适配。")
        }
    }

    private func settingLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            XboxIconBadge(systemName: icon, color: color, size: 28)
            Text(title)
        }
    }
}
