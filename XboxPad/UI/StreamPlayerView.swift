import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import XboxPadNanoFFI

struct StreamPlayerView: View {
    let target: StreamTarget
    let onDismiss: () -> Void

    @EnvironmentObject var appState: AppState
    @StateObject private var session: NanoStreamSession
    @ObservedObject private var externalDisplay = ExternalDisplayManager.shared
    @State private var showOverlayBar = false
    @State private var showMoreDrawer = false
    @State private var showHUD: Bool
    @State private var manualVirtualGamepad = false
    @State private var isEditingVirtualLayout = false
    @State private var showCastSheet = false
    @State private var showSettingsSheet = false
    @State private var isBlackoutDimmerActive = false
    @State private var shutterFlashOpacity: Double = 0

    init(
        target: StreamTarget,
        authService: XboxAuthService,
        gamepadManager: GamepadManager,
        settings: AppSettings,
        onDismiss: @escaping () -> Void
    ) {
        self.target = target
        self.onDismiss = onDismiss
        _session = StateObject(
            wrappedValue: NanoStreamSession(
                target: target,
                authService: authService,
                gamepadManager: gamepadManager,
                settings: settings
            )
        )
        _showHUD = State(initialValue: settings.showPerformanceHUD)
    }

    private var shouldShowVirtualGamepad: Bool {
        #if os(macOS)
        return false
        #else
        guard case .streaming = session.connectionState else { return false }
        let hasHardwareInput = appState.gamepadManager.telemetry.connected
            || (appState.settings.keyboardMouseMode != .off
                && (appState.gamepadManager.telemetry.keyboardConnected || appState.gamepadManager.telemetry.mouseConnected))
        return manualVirtualGamepad
            || (appState.settings.showVirtualControlsWhenNoGamepad && !hasHardwareInput)
        #endif
    }

    private func closeOverlayBar() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
            showMoreDrawer = false
            showOverlayBar = false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if externalDisplay.isRenderingExternally {
                externalDisplayDashboard
            } else {
                VideoDecoderView(
                    renderer: session.videoRenderer,
                    aspectMode: appState.settings.aspectMode,
                    hdrToneMode: appState.settings.hdrToneMode
                )
                .ignoresSafeArea()
            }

            // Invisible top-center tap zone to open the bar when hidden
            if !externalDisplay.isRenderingExternally && !showOverlayBar {
                VStack {
                    Color.clear
                        .frame(height: 54)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                showOverlayBar = true
                            }
                        }
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
            }

            // Full-screen tap-to-dismiss layer whenever the top bar is open:
            // tap ANYWHERE on the game area to close the bar & more drawer effortlessly!
            if showOverlayBar && !externalDisplay.isRenderingExternally {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeOverlayBar()
                    }
            }

            // Performance HUD + Live 30s Latency Sparkline + REC indicator
            if (showHUD || session.isRecording), !externalDisplay.isRenderingExternally, case .streaming = session.connectionState {
                VStack {
                    HStack(spacing: 8) {
                        if showHUD {
                            performanceHUD
                        }
                        if session.isRecording {
                            recordingLiveBadge
                        }
                        Spacer()
                    }
                    .padding(.top, showOverlayBar ? (showMoreDrawer ? 196 : 74) : 14)
                    .padding(.horizontal, 16)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Optional FPS Center Crosshair Overlay
            if appState.settings.crosshairEnabled, !externalDisplay.isRenderingExternally, case .streaming = session.connectionState {
                FPSCrosshairOverlay(style: appState.settings.crosshairStyle)
                    .allowsHitTesting(false)
            }

            // Full multi-touch virtual gamepad overlay
            if shouldShowVirtualGamepad, !isBlackoutDimmerActive {
                VirtualGamepadOverlay(
                    gamepadManager: appState.gamepadManager,
                    opacity: appState.settings.virtualGamepadOpacity,
                    scaleMultiplier: appState.settings.virtualGamepadScale,
                    floatingStick: appState.settings.virtualGamepadFloatingStick,
                    hapticTap: appState.settings.virtualGamepadHapticTap,
                    isEditingLayout: $isEditingVirtualLayout,
                    savedOffsets: $appState.settings.virtualGamepadOffsets
                )
                .ignoresSafeArea()
            }

            // Compact top floating control bar + expandable 2-row quick drawer
            if showOverlayBar || externalDisplay.isRenderingExternally {
                VStack(spacing: 10) {
                    topControlBar
                        .padding(.top, 12)
                        .padding(.horizontal, 16)

                    if showMoreDrawer {
                        moreToolsDrawer
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Toast notification banner
            if let toast = session.toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .overlay(Capsule().stroke(XboxTheme.emeraldBright.opacity(0.45), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                        .padding(.bottom, 34)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Camera shutter flash effect on screenshot
            if shutterFlashOpacity > 0.001 {
                Color.white
                    .opacity(shutterFlashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // OLED Power-Save Blackout Dimmer
            if isBlackoutDimmerActive {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "moon.stars.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.24))
                        Text("外接投屏省电模式 · 轻点唤醒 iPad 控制台")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.24))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBlackoutDimmerActive = false
                    }
                }
            }

            connectionOverlay
        }
        .xboxHideSystemChrome()
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadToggleFullscreen)) { _ in
            #if os(macOS)
            XboxPlatform.toggleWindowFullScreen()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadToggleOverlay)) { _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                if showOverlayBar {
                    showMoreDrawer = false
                    showOverlayBar = false
                } else {
                    showOverlayBar = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadOpenSettings)) { _ in
            showOverlayBar = false
            showMoreDrawer = false
            showSettingsSheet.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadCaptureScreenshot)) { _ in
            closeOverlayBar()
            triggerScreenshotCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadToggleRecording)) { _ in
            session.toggleRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadSaveReplay)) { _ in
            session.saveInstantReplay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xboxpadToggleMic)) { _ in
            session.toggleMicrophone()
        }
        .sheet(isPresented: $showCastSheet) {
            castControlSheet
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(
                gamepadManager: appState.gamepadManager,
                initialCategory: .gamepad,
                onClose: {
                    showSettingsSheet = false
                }
            )
            .environmentObject(appState)
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 580)
            #endif
        }
        .onAppear {
            XboxPlatform.setIdleSleepDisabled(true)
            XboxPlatform.setPreferredLandscapeForStreaming(true)
            #if os(macOS)
            XboxPlatform.applyWindowAspectLock(appState.settings.macLock16x9Window)
            #endif
            syncStreamOverlayFlag()
            appState.gamepadManager.onToggleOverlayRequested = {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    if showOverlayBar {
                        showMoreDrawer = false
                        showOverlayBar = false
                    } else {
                        showOverlayBar = true
                    }
                }
            }
            externalDisplay.bindStream(
                renderer: session.videoRenderer,
                title: target.displayTitle,
                hdrToneMode: appState.settings.hdrToneMode,
                fullscreenEnabled: appState.settings.externalDisplayFullscreen
            )
            session.start()
        }
        .onDisappear {
            XboxPlatform.setIdleSleepDisabled(false)
            XboxPlatform.setPreferredLandscapeForStreaming(false)
            #if os(macOS)
            XboxPlatform.applyWindowAspectLock(false)
            #endif
            appState.isStreamOverlayOpen = false
            appState.gamepadManager.onToggleOverlayRequested = nil
            externalDisplay.unbindStream(renderer: session.videoRenderer)
            session.stop()
        }
        .onChange(of: showOverlayBar) { _ in syncStreamOverlayFlag() }
        .onChange(of: showSettingsSheet) { _ in syncStreamOverlayFlag() }
        .onChange(of: showCastSheet) { _ in syncStreamOverlayFlag() }
        .onChange(of: appState.settings) { newSettings in
            session.updateSettings(newSettings)
            showHUD = newSettings.showPerformanceHUD
            externalDisplay.updateStreamHDR(newSettings.hdrToneMode)
            externalDisplay.isExternalOutputEnabled = newSettings.externalDisplayFullscreen
            #if os(macOS)
            XboxPlatform.applyWindowAspectLock(newSettings.macLock16x9Window)
            #endif
        }
    }

    private func syncStreamOverlayFlag() {
        appState.isStreamOverlayOpen = showOverlayBar || showSettingsSheet || showCastSheet
    }

    private var recordingElapsedLabel: String {
        let m = session.recordingElapsedSec / 60
        let s = session.recordingElapsedSec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var recordingLiveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("REC \(recordingElapsedLabel)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.28), in: Capsule())
        .background(Color.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.65), lineWidth: 1))
    }

    // MARK: - Telemetry HUD + Dual-Line Sparkline

    private var performanceHUD: some View {
        let s = session.stats
        let fpsText: String = {
            guard s.fps >= 0 else { return "--" }
            let dispFps = session.videoRenderer.measuredDisplayFps
            if appState.settings.frameInterpolation120Hz && session.videoRenderer.isHardwareInterpolationActive {
                let shown = dispFps >= 65 ? dispFps : (s.fps * 2.0)
                return "\(Int(shown.rounded()))*"
            }
            return String(format: "%.0f", s.fps)
        }()
        let rttText = s.rttMs >= 0 ? String(format: "%.1fms", s.rttMs) : "--"
        let bitrateText = s.bitrateMbps >= 0 ? String(format: "%.1fM", s.bitrateMbps) : "--"
        let lossText = s.packetLossPct >= 0 ? String(format: "%.1f%%", s.packetLossPct) : "0%"
        let decodeText = s.decodeMs >= 0 ? String(format: "%.1fms", s.decodeMs) : "--"
        let audioText = s.audioBufferMs >= 0 ? String(format: "%.0fms", s.audioBufferMs) : "--"
        let isMetalFX = session.videoRenderer.isMetalFXActive
        let isThermalWarning = session.thermalState == .serious || session.thermalState == .critical

        let routeColor: Color = {
            switch s.routeKind {
            case 1: return XboxTheme.emeraldBright
            case 2: return XboxTheme.info
            default: return XboxTheme.warning
            }
        }()

        return HStack(spacing: 10) {
            if s.routeKind != 0 {
                HStack(spacing: 5) {
                    Circle()
                        .fill(routeColor)
                        .frame(width: 6, height: 6)
                    Text(s.routeBadgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(routeColor)
                }
                hudDivider
            }

            hudMetric(title: "FPS", value: fpsText, good: s.fps >= 55)
            hudDivider
            hudMetric(title: "RTT", value: rttText, good: s.rttMs > 0 && s.rttMs <= 30)
            hudDivider
            hudMetric(title: "码率", value: bitrateText, good: true)
            hudDivider
            hudMetric(title: "丢包", value: lossText, good: s.packetLossPct < 0.5)
            hudDivider
            hudMetric(title: "解码", value: decodeText, good: true)
            hudDivider
            hudMetric(title: "音频", value: audioText, good: s.audioBufferMs <= 80)

            if session.latencyHistory.count >= 2 {
                hudDivider
                LatencySparklineView(samples: session.latencyHistory)
                    .frame(width: 58, height: 16)
            }

            if isMetalFX {
                hudDivider
                Text("MFX")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.18), in: Capsule())
            }

            if isThermalWarning {
                hudDivider
                Image(systemName: "thermometer.high")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.66), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.9))
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 11)
    }

    private func hudMetric(title: String, value: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(good ? XboxTheme.emeraldBright : XboxTheme.warning)
        }
    }

    // MARK: - Clean Primary Top Bar (Pinned Close Button + Compact Primary Actions)

    private var compactStreamTitle: String {
        let raw = target.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count > 12 else { return raw }
        return String(raw.prefix(11)) + "…"
    }

    private var topControlBar: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                session.stop()
                onDismiss()
            } label: {
                Label("退出", systemImage: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(XboxTheme.danger.opacity(0.88), in: Capsule())
            }
            .buttonStyle(.plain)

            if !XboxPlatform.isPhone {
                Text(compactStreamTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 18)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Menu {
                        Button {
                            appState.gamepadManager.pulseNexusButton()
                        } label: {
                            Label("短按西瓜键 (打开指南)", systemImage: "xbox.logo")
                        }
                        Button {
                            appState.gamepadManager.holdNexusButton(durationMs: 1200)
                        } label: {
                            Label("长按西瓜键 (电源/关机菜单)", systemImage: "power.circle")
                        }
                    } label: {
                        Label("Xbox", systemImage: "xbox.logo")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(XboxTheme.primaryGradient, in: Capsule())
                    } primaryAction: {
                        appState.gamepadManager.pulseNexusButton()
                    }

                    if LocalFrameInterpolationSupport.isSupported {
                        overlayChipButton(
                            title: appState.settings.frameInterpolation120Hz ? "120Hz" : "60Hz",
                            systemImage: "wand.and.stars",
                            active: appState.settings.frameInterpolation120Hz,
                            activeColor: .cyan
                        ) {
                            appState.settings.frameInterpolation120Hz.toggle()
                        }
                    }

                    overlayChipButton(
                        title: appState.settings.hdrToneMode.shortLabel,
                        systemImage: "sun.max.fill",
                        active: appState.settings.hdrToneMode != .off,
                        activeColor: .orange
                    ) {
                        cycleHDRToneMode()
                    }

                    #if os(macOS)
                    overlayChipButton(
                        title: "全屏",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        active: false,
                        activeColor: XboxTheme.info
                    ) {
                        XboxPlatform.toggleWindowFullScreen()
                    }
                    #else
                    overlayChipButton(
                        title: externalDisplay.isRenderingExternally
                            ? "外接全屏"
                            : (externalDisplay.isScreenMirrored ? "镜像中" : "投屏"),
                        systemImage: "airplayvideo",
                        active: externalDisplay.isRenderingExternally || externalDisplay.isScreenMirrored,
                        activeColor: XboxTheme.info
                    ) {
                        externalDisplay.refreshScreenState()
                        showCastSheet = true
                    }
                    #endif

                    overlayChipButton(
                        title: session.isMuted ? "静音" : "声音",
                        systemImage: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: !session.isMuted,
                        activeColor: XboxTheme.emeraldBright
                    ) {
                        session.toggleMute()
                    }

                    overlayChipButton(
                        title: session.isMicEnabled ? "开麦中" : "开麦",
                        systemImage: session.isMicEnabled ? "mic.fill" : "mic.slash.fill",
                        active: session.isMicEnabled,
                        activeColor: Color(red: 1.0, green: 0.34, blue: 0.36)
                    ) {
                        session.toggleMicrophone()
                    }

                    overlayChipButton(
                        title: session.isRecording ? recordingElapsedLabel : "录屏",
                        systemImage: session.isRecording ? "stop.circle.fill" : "record.circle",
                        active: session.isRecording,
                        activeColor: Color(red: 1.0, green: 0.28, blue: 0.32)
                    ) {
                        session.toggleRecording()
                    }

                    if appState.settings.instantReplayEnabled {
                        overlayChipButton(
                            title: session.isSavingReplay ? "保存中" : "回放30s",
                            systemImage: "clock.arrow.circlepath",
                            active: session.isSavingReplay,
                            activeColor: .orange
                        ) {
                            session.saveInstantReplay()
                        }
                    }

                    overlayChipButton(
                        title: "设置",
                        systemImage: "slider.horizontal.3",
                        active: showSettingsSheet,
                        activeColor: XboxTheme.emeraldBright
                    ) {
                        closeOverlayBar()
                        showSettingsSheet = true
                    }

                    overlayChipButton(
                        title: "更多",
                        systemImage: showMoreDrawer ? "chevron.up.circle.fill" : "ellipsis.circle.fill",
                        active: showMoreDrawer,
                        activeColor: XboxTheme.emeraldBright
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                            showMoreDrawer.toggle()
                        }
                    }
                }
            }

            // Always-pinned, prominent close button outside ScrollView (never scrolled off-screen!)
            if !externalDisplay.isRenderingExternally {
                Button {
                    closeOverlayBar()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.caption.bold())
                        Text("收起")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.50), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
    }

    // MARK: - Secondary Tools Quick Drawer (Clean 2-Row Grid)

    private var moreToolsDrawer: some View {
        let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
        return LazyVGrid(columns: gridColumns, spacing: 8) {
            drawerTile(
                title: aspectShortName(appState.settings.aspectMode),
                systemImage: "aspectratio",
                active: appState.settings.aspectMode != .fit,
                activeColor: XboxTheme.emeraldBright
            ) {
                cycleAspectMode()
            }

            drawerTile(
                title: sharpenShortName(appState.settings.sharpeningLevel),
                systemImage: "camera.filters",
                active: appState.settings.sharpeningLevel != .off,
                activeColor: XboxTheme.emeraldBright
            ) {
                cycleSharpeningLevel()
            }

            drawerTile(
                title: "截屏",
                systemImage: "camera.shutter.button.fill",
                active: false
            ) {
                closeOverlayBar()
                triggerScreenshotCapture()
            }

            drawerTile(
                title: session.isRecording ? "停止录屏" : "原画录屏",
                systemImage: session.isRecording ? "stop.circle.fill" : "record.circle",
                active: session.isRecording,
                activeColor: Color(red: 1.0, green: 0.28, blue: 0.32)
            ) {
                session.toggleRecording()
            }

            drawerTile(
                title: "回放30s",
                systemImage: "clock.arrow.circlepath",
                active: session.isSavingReplay,
                activeColor: .orange
            ) {
                closeOverlayBar()
                session.saveInstantReplay()
            }

            drawerTile(
                title: appState.settings.crosshairEnabled ? "准星开" : "FPS准星",
                systemImage: "scope",
                active: appState.settings.crosshairEnabled,
                activeColor: XboxTheme.emeraldBright
            ) {
                appState.settings.crosshairEnabled.toggle()
            }

            #if os(iOS)
            if shouldShowVirtualGamepad {
                drawerTile(
                    title: isEditingVirtualLayout ? "完成排版" : "按键排版",
                    systemImage: "hand.draw.fill",
                    active: isEditingVirtualLayout,
                    activeColor: .teal
                ) {
                    closeOverlayBar()
                    isEditingVirtualLayout.toggle()
                }
            }
            #endif

            drawerTile(
                title: manualVirtualGamepad ? "触控开" : "触控手柄",
                systemImage: "gamecontroller.fill",
                active: manualVirtualGamepad,
                activeColor: .teal
            ) {
                manualVirtualGamepad.toggle()
            }

            drawerTile(
                title: appState.settings.keyboardMouseMode.shortLabel,
                systemImage: "keyboard",
                active: appState.settings.keyboardMouseMode != .off,
                activeColor: XboxTheme.info
            ) {
                cycleKeyboardMouseMode()
            }

            drawerTile(
                title: appState.settings.rumbleEnabled ? "震动开" : "震动关",
                systemImage: appState.settings.rumbleEnabled ? "iphone.radiowaves.left.and.right" : "slash.circle",
                active: appState.settings.rumbleEnabled,
                activeColor: XboxTheme.emeraldBright
            ) {
                appState.settings.rumbleEnabled.toggle()
            }

            drawerTile(
                title: showHUD ? "监控开" : "监控关",
                systemImage: "speedometer",
                active: showHUD,
                activeColor: XboxTheme.info
            ) {
                showHUD.toggle()
            }

            drawerTile(
                title: "刷新画面",
                systemImage: "sparkles.tv",
                active: false
            ) {
                session.videoRenderer.resetForForeground()
                session.requestKeyframe()
                closeOverlayBar()
            }

            drawerTile(
                title: "重连",
                systemImage: "arrow.triangle.2.circlepath",
                active: false
            ) {
                closeOverlayBar()
                session.reconnectManually()
            }

            drawerTile(
                title: "设置手柄",
                systemImage: "slider.horizontal.3",
                active: showSettingsSheet,
                activeColor: XboxTheme.emeraldBright
            ) {
                closeOverlayBar()
                showSettingsSheet = true
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }

    private func drawerTile(
        title: String,
        systemImage: String,
        active: Bool,
        activeColor: Color = XboxTheme.emeraldBright,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? activeColor : .white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                active ? activeColor.opacity(0.18) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? activeColor.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - External Display Dashboard

    private var externalDisplayDashboard: some View {
        ZStack {
            XboxAmbientBackground(intensity: 0.9)

            VStack(spacing: 22) {
                Spacer(minLength: 70)

                VStack(spacing: 12) {
                    XboxIconBadge(systemName: "tv.and.hifispeaker.fill", color: XboxTheme.info, size: 64)
                    Text("外接显示器 16:9 全屏输出中")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        if !externalDisplay.externalResolutionText.isEmpty {
                            XboxStatusPill(text: externalDisplay.externalResolutionText, color: XboxTheme.info, pulse: true)
                        }
                        XboxStatusPill(text: "\(externalDisplay.externalRefreshHz)Hz", color: XboxTheme.emeraldBright, pulse: false)
                        if externalDisplay.externalEDRHeadroom > 1.05 {
                            XboxStatusPill(
                                text: String(format: "HDR %.1f×", externalDisplay.externalEDRHeadroom),
                                color: .orange,
                                pulse: false
                            )
                        }
                    }
                }

                performanceHUD

                HStack(spacing: 14) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isBlackoutDimmerActive = true
                        }
                    } label: {
                        Label("iPad 纯黑省电遮罩", systemImage: "moon.fill")
                    }
                    .buttonStyle(XboxPrimaryButtonStyle(compact: true))

                    Button {
                        appState.settings.externalDisplayFullscreen = false
                        externalDisplay.isExternalOutputEnabled = false
                    } label: {
                        Label("切回 iPad 本机画面", systemImage: "ipad.landscape")
                    }
                    .buttonStyle(XboxSecondaryButtonStyle(compact: true))
                }

                Spacer()
            }
            .padding(24)
        }
    }

    // MARK: - Cast & AirPlay Sheet

    private var castControlSheet: some View {
        NavigationStack {
            ZStack {
                XboxAmbientBackground(intensity: 0.8)

                List {
                    Section {
                        HStack(spacing: 14) {
                            XboxIconBadge(
                                systemName: externalDisplay.hasExternalScene ? "display" : (externalDisplay.isScreenMirrored ? "airplayvideo" : "tv"),
                                color: (externalDisplay.hasExternalScene || externalDisplay.isScreenMirrored) ? XboxTheme.emeraldBright : .secondary,
                                size: 42
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    externalDisplay.hasExternalScene
                                        ? "已连接外接显示器 (\(externalDisplay.externalResolutionText))"
                                        : (externalDisplay.isScreenMirrored ? "正在 AirPlay 屏幕镜像投屏" : "未检测到有线/扩展外接屏")
                                )
                                .font(.headline)
                                .foregroundStyle(.white)
                                Text(
                                    externalDisplay.hasExternalScene
                                        ? "刷新率 \(externalDisplay.externalRefreshHz)Hz · 支持原生 16:9 无黑边全屏"
                                        : "连接 USB-C / HDMI 线或开启扩展屏后自动 16:9 满屏输出"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(XboxTheme.surface)

                        Toggle("外接显示器独立 16:9 全屏模式", isOn: $appState.settings.externalDisplayFullscreen)
                            .listRowBackground(XboxTheme.surface)

                        if externalDisplay.isRenderingExternally {
                            Button {
                                showCastSheet = false
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    isBlackoutDimmerActive = true
                                }
                            } label: {
                                Label("开启 iPad 纯黑省电遮罩", systemImage: "moon.stars.fill")
                                    .foregroundStyle(XboxTheme.emeraldBright)
                            }
                            .listRowBackground(XboxTheme.surface)
                        }
                    } header: {
                        Text("有线 USB-C / HDMI 外接大屏")
                    }

                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("选择 AirPlay 电视 / 音频设备")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("切换 Apple TV、AirPlay 2 电视或 HomePod")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            AirPlayRoutePickerView()
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.10), in: Circle())
                        }
                        .listRowBackground(XboxTheme.surface)

                        Text("无线整屏投屏：下拉 iPad 右上角「控制中心」→「屏幕镜像」选择电视即可。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(XboxTheme.surface)
                    } header: {
                        Text("无线 AirPlay 隔空投屏")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("投屏与外接显示器")
            .xboxInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showCastSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func triggerScreenshotCapture() {
        withAnimation(.easeOut(duration: 0.08)) {
            shutterFlashOpacity = 0.65
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            withAnimation(.easeOut(duration: 0.22)) {
                shutterFlashOpacity = 0
            }
        }
        session.captureScreenshotToPhotos { _ in }
    }

    private func overlayChipButton(
        title: String,
        systemImage: String,
        active: Bool,
        activeColor: Color = XboxTheme.emeraldBright,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? activeColor : .white.opacity(0.86))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                (active ? activeColor.opacity(0.18) : Color.white.opacity(0.09)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(active ? activeColor.opacity(0.48) : Color.white.opacity(0.10), lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connection Modal

    @ViewBuilder
    private var connectionOverlay: some View {
        switch session.connectionState {
        case .streaming, .idle:
            EmptyView()
        case .connecting(let msg):
            statusModal(title: target.displayTitle, message: msg, isError: false)
        case .reconnecting(_, let msg):
            statusModal(title: "正在自动重连", message: msg, isError: false)
        case .failed(let msg):
            statusModal(title: "串流连接中断", message: msg, isError: true)
        }
    }

    private func statusModal(title: String, message: String, isError: Bool) -> some View {
        VStack(spacing: 18) {
            if isError {
                XboxIconBadge(systemName: "wifi.exclamationmark", color: XboxTheme.warning, size: 58)
            } else {
                ZStack {
                    Circle()
                        .fill(XboxTheme.emerald.opacity(0.14))
                        .frame(width: 64, height: 64)
                    ProgressView()
                        .controlSize(.large)
                        .tint(XboxTheme.emeraldBright)
                }
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 12) {
                if isError {
                    Button {
                        session.reconnectManually()
                    } label: {
                        Label("立即重连", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(XboxPrimaryButtonStyle(compact: true))
                }

                Button("退出串流", role: .cancel) {
                    session.stop()
                    onDismiss()
                }
                .buttonStyle(XboxSecondaryButtonStyle(compact: true))
            }
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(XboxTheme.bgDeep.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    isError
                        ? AnyShapeStyle(XboxTheme.warning.opacity(0.35))
                        : AnyShapeStyle(XboxTheme.emeraldBorderGradient),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 24)
    }

    private func cycleAspectMode() {
        let all = VideoAspectMode.allCases
        if let idx = all.firstIndex(of: appState.settings.aspectMode) {
            appState.settings.aspectMode = all[(idx + 1) % all.count]
        }
    }

    private func aspectShortName(_ mode: VideoAspectMode) -> String {
        switch mode {
        case .fit: return "16:9"
        case .stretch: return "拉伸"
        case .fill: return "铺满"
        }
    }

    private func cycleSharpeningLevel() {
        let all = VideoSharpeningLevel.allCases
        if let idx = all.firstIndex(of: appState.settings.sharpeningLevel) {
            appState.settings.sharpeningLevel = all[(idx + 1) % all.count]
        }
    }

    private func sharpenShortName(_ level: VideoSharpeningLevel) -> String {
        switch level {
        case .off: return "锐化关"
        case .light: return "锐化轻"
        case .medium: return "锐化中"
        case .strong: return "锐化强"
        }
    }

    private func cycleHDRToneMode() {
        let all = VideoHDRToneMode.allCases
        if let idx = all.firstIndex(of: appState.settings.hdrToneMode) {
            appState.settings.hdrToneMode = all[(idx + 1) % all.count]
        }
    }

    private func cycleKeyboardMouseMode() {
        let all = KeyboardMouseMode.allCases
        if let idx = all.firstIndex(of: appState.settings.keyboardMouseMode) {
            appState.settings.keyboardMouseMode = all[(idx + 1) % all.count]
        }
    }
}

/// Compact dual-trace sparkline rendered inside the floating performance HUD:
/// - Emerald trace: Network RTT (ms)
/// - Cyan trace: Video pipeline latency (ms)
private struct LatencySparklineView: View {
    let samples: [LatencySample]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxVal = max(
                samples.map { max($0.rttMs, $0.pipeMs) }.max() ?? 30.0,
                25.0
            )
            let count = max(samples.count - 1, 1)

            ZStack {
                Path { path in
                    for (idx, s) in samples.enumerated() {
                        let x = w * CGFloat(idx) / CGFloat(count)
                        let y = h * (1.0 - CGFloat(min(s.pipeMs / maxVal, 1.0)))
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.cyan.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

                Path { path in
                    for (idx, s) in samples.enumerated() {
                        let x = w * CGFloat(idx) / CGFloat(count)
                        let y = h * (1.0 - CGFloat(min(s.rttMs / maxVal, 1.0)))
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(XboxTheme.emeraldBright, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct FPSCrosshairOverlay: View {
    let style: CrosshairStyle

    var body: some View {
        let color = XboxTheme.emeraldBright.opacity(0.92)
        ZStack {
            switch style {
            case .dot:
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .shadow(color: .black.opacity(0.85), radius: 1.5)
            case .plus:
                Group {
                    Rectangle().fill(color).frame(width: 18, height: 1.8)
                    Rectangle().fill(color).frame(width: 1.8, height: 18)
                }
                .shadow(color: .black.opacity(0.85), radius: 1.5)
            case .dotPlus:
                Group {
                    Circle().fill(color).frame(width: 3.5, height: 3.5)
                    Rectangle().fill(color).frame(width: 7, height: 1.6).offset(x: -9)
                    Rectangle().fill(color).frame(width: 7, height: 1.6).offset(x: 9)
                    Rectangle().fill(color).frame(width: 1.6, height: 7).offset(y: -9)
                    Rectangle().fill(color).frame(width: 1.6, height: 7).offset(y: 9)
                }
                .shadow(color: .black.opacity(0.85), radius: 1.5)
            case .circleDot:
                Group {
                    Circle().stroke(color, lineWidth: 1.5).frame(width: 22, height: 22)
                    Circle().fill(color).frame(width: 3.8, height: 3.8)
                }
                .shadow(color: .black.opacity(0.85), radius: 1.5)
            }
        }
    }
}
