import Foundation
import Network
import os
import QuartzCore
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import XboxPadNanoFFI

private let nanoLogger = Logger(subsystem: "com.elliot.xboxpad", category: "nano")

private func installRustLogBridgeOnce() {
    struct Once {
        static let installed: Bool = {
            xboxpad_set_log_callback { level, msgPtr in
                guard let msgPtr else { return }
                let msg = String(cString: msgPtr)
                switch level {
                case 2:
                    nanoLogger.error("\(msg, privacy: .public)")
                case 1:
                    nanoLogger.warning("\(msg, privacy: .public)")
                default:
                    nanoLogger.info("\(msg, privacy: .public)")
                }
            }
            return true
        }()
    }
    _ = Once.installed
}

enum StreamConnectionState: Equatable {
    case idle
    case connecting(String)
    case streaming
    case reconnecting(Int, String)
    case failed(String)
}

/// High-level streaming session coordinator bridging Rust `xboxpad_nano` FFI,
/// VideoToolbox H.264 renderer, AudioToolbox Opus engine, CoreHaptics, and auto-reconnect.
@MainActor
final class NanoStreamSession: ObservableObject {
    @Published private(set) var connectionState: StreamConnectionState = .idle
    @Published private(set) var stats = LiveStreamStats()
    @Published private(set) var isMuted = false
    @Published private(set) var isMicEnabled = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsedSec: Int = 0
    @Published private(set) var isSavingReplay = false
    @Published private(set) var latencyHistory: [LatencySample] = []
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var toastMessage: String?

    let videoRenderer = H264StreamRenderer()
    let audioEngine = OpusAudioEngine()
    let micEngine = MicrophoneEngine()
    let recorder = StreamRecorder()
    let replayBuffer = InstantReplayBuffer()

    private let authService: XboxAuthService
    private let gamepadManager: GamepadManager
    private let target: StreamTarget
    private var settings: AppSettings

    private final class ThreadSafeHandleBox: @unchecked Sendable {
        private var lock = os_unfair_lock_s()
        private var handle: OpaquePointer?

        func set(_ newHandle: OpaquePointer?) {
            os_unfair_lock_lock(&lock)
            handle = newHandle
            os_unfair_lock_unlock(&lock)
        }

        func take() -> OpaquePointer? {
            os_unfair_lock_lock(&lock)
            let old = handle
            handle = nil
            os_unfair_lock_unlock(&lock)
            return old
        }

        func sendInput(_ frame: XboxPadInputFrame) {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                var mutable = frame
                _ = xboxpad_send_input(h, &mutable)
            }
            os_unfair_lock_unlock(&lock)
        }

        func requestKeyframe() {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                _ = xboxpad_request_keyframe(h)
            }
            os_unfair_lock_unlock(&lock)
        }

        func sendMicOpus(_ data: Data, durationMs: UInt32) {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count > 0 {
                        _ = xboxpad_send_mic_opus(h, base, data.count, durationMs)
                    }
                }
            }
            os_unfair_lock_unlock(&lock)
        }

        func setGamepadConnected(index: UInt8, connected: Bool) {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                _ = xboxpad_set_gamepad_connected(h, index, connected)
            }
            os_unfair_lock_unlock(&lock)
        }

        func sendMouse(x: Int32, y: Int32, wheelX: Int32, wheelY: Int32, buttons: UInt8, relative: UInt8) {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                _ = xboxpad_send_mouse(h, x, y, wheelX, wheelY, buttons, relative)
            }
            os_unfair_lock_unlock(&lock)
        }

        func sendKeyboard(keyCode: UInt8, pressed: Bool) {
            os_unfair_lock_lock(&lock)
            if let h = handle {
                _ = xboxpad_send_keyboard(h, keyCode, pressed)
            }
            os_unfair_lock_unlock(&lock)
        }
    }

    static var hasBuiltInRelayCluster: Bool {
        xboxpad_has_builtin_ice()
    }

    private let handleBox = ThreadSafeHandleBox()
    private var callbackContext: UnsafeMutableRawPointer?
    private var isStoppedByUser = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?
    private var iceConnectWatchdogTask: Task<Void, Never>?
    private var disconnectWatchdogTask: Task<Void, Never>?
    private var stallWatchdogTask: Task<Void, Never>?
    private var forceIPv4RetryOnce = false
    private var toastClearTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.elliot.xboxpad.netpath", qos: .utility)
    private var lastNetworkSignature: String?
    private var isAppInBackground = false
    private var lastVideoFrameTimestamp: CFTimeInterval = 0
    private var stallSoftRecovered = false
    private var latestDecodeMs: Double = -1
    private var statsLogTick: Int = 0
    private var latencySampleSeq: Int = 0

    init(
        target: StreamTarget,
        authService: XboxAuthService,
        gamepadManager: GamepadManager,
        settings: AppSettings
    ) {
        installRustLogBridgeOnce()
        self.target = target
        self.authService = authService
        self.gamepadManager = gamepadManager
        self.settings = settings

        let handleBox = self.handleBox
        videoRenderer.onNeedKeyframe = {
            handleBox.requestKeyframe()
        }
        videoRenderer.onFirstFrameRendered = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectAttempt = 0
                self.forceIPv4RetryOnce = false
                self.lastVideoFrameTimestamp = CACurrentMediaTime()
                self.stallSoftRecovered = false
                self.iceConnectWatchdogTask?.cancel()
                self.iceConnectWatchdogTask = nil
                self.disconnectWatchdogTask?.cancel()
                self.connectionState = .streaming
                self.startStallWatchdog()
                if self.isAppInBackground {
                    self.notifyStreamReadyInBackground()
                }
            }
        }
        videoRenderer.onDecodeTiming = { [weak self] ms in
            self?.latestDecodeMs = ms
        }
        micEngine.onOpusPacket = { data, durationMs in
            handleBox.sendMicOpus(data, durationMs: durationMs)
        }
        micEngine.onMicLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micLevel = level
            }
        }

        setupLifecycleObservers()
        syncThermalProtection()
    }

    deinit {
        pathMonitor?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        micEngine.stop()
        if let handle = handleBox.take() {
            xboxpad_destroy(handle)
        }
        if let ctx = callbackContext {
            Unmanaged<NanoStreamSession>.fromOpaque(ctx).release()
        }
    }

    func start() {
        isStoppedByUser = false
        reconnectAttempt = 0
        forceIPv4RetryOnce = false
        reconnectTask?.cancel()
        iceConnectWatchdogTask?.cancel()
        iceConnectWatchdogTask = nil
        disconnectWatchdogTask?.cancel()
        stallWatchdogTask?.cancel()
        latencyHistory.removeAll(keepingCapacity: true)
        startNetworkPathMonitor()

        gamepadManager.settings = settings
        let handleBox = self.handleBox
        gamepadManager.onInputFrame = { frame in
            handleBox.sendInput(frame)
        }
        gamepadManager.onGamepadSlotChanged = { idx, connected in
            handleBox.setGamepadConnected(index: idx, connected: connected)
        }
        gamepadManager.onMouseEvent = { dx, dy, wx, wy, btns, rel in
            handleBox.sendMouse(x: dx, y: dy, wheelX: wx, wheelY: wy, buttons: btns, relative: rel)
        }
        gamepadManager.onKeyboardEvent = { vk, pressed in
            handleBox.sendKeyboard(keyCode: vk, pressed: pressed)
        }
        gamepadManager.setStreamingActive(true)
        videoRenderer.updateFramePacingMode(settings.framePacingMode)
        videoRenderer.updateFrameInterpolation(settings.frameInterpolation120Hz)
        videoRenderer.updateSharpeningLevel(settings.sharpeningLevel)
        videoRenderer.updateHDRToneMode(settings.hdrToneMode)
        videoRenderer.updateDebanding(settings.debandingEnabled)
        videoRenderer.updateMetalFX(settings.metalFXUpscaling)
        videoRenderer.updateColorGrading(
            shadowLift: settings.shadowLift,
            brightness: settings.videoBrightness,
            contrast: settings.videoContrast,
            saturation: settings.videoSaturation
        )
        videoRenderer.updateZoomScale(settings.videoZoomScale)
        replayBuffer.reset()
        replayBuffer.setEnabled(settings.instantReplayEnabled)
        micEngine.echoCancellationEnabled = settings.micEchoCancellation
        if !target.isHome {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        syncThermalProtection()
        audioEngine.setPacingMode(settings.framePacingMode)
        audioEngine.start(sampleRate: 48_000, channels: settings.stereoAudio ? 2 : 1)
        gamepadManager.haptics.prepareForStream()

        Task {
            await connectOnce(forceTokenRefresh: false)
        }
    }

    private struct DestroyBox: @unchecked Sendable {
        let handle: OpaquePointer
        let ctx: UnsafeMutableRawPointer?
    }

    func stop() {
        isStoppedByUser = true
        reconnectTask?.cancel()
        reconnectTask = nil
        iceConnectWatchdogTask?.cancel()
        iceConnectWatchdogTask = nil
        disconnectWatchdogTask?.cancel()
        disconnectWatchdogTask = nil
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkSignature = nil

        gamepadManager.setStreamingActive(false)
        gamepadManager.onInputFrame = nil
        gamepadManager.onGamepadSlotChanged = nil
        gamepadManager.onMouseEvent = nil
        gamepadManager.onKeyboardEvent = nil
        gamepadManager.haptics.stopAll()
        micEngine.stop()
        isMicEnabled = false
        micLevel = 0
        if isRecording {
            stopRecordingSilently()
        }
        replayBuffer.reset()
        audioEngine.stop()

        let handleToStop = handleBox.take()
        let ctxToRelease = callbackContext
        callbackContext = nil

        if let handleToStop {
            // Stop off main thread so UI dismisses immediately without blocking on thread join
            let box = DestroyBox(handle: handleToStop, ctx: ctxToRelease)
            DispatchQueue.global(qos: .userInitiated).async {
                xboxpad_destroy(box.handle)
                if let ctx = box.ctx {
                    Unmanaged<NanoStreamSession>.fromOpaque(ctx).release()
                }
            }
        } else if let ctxToRelease {
            Unmanaged<NanoStreamSession>.fromOpaque(ctxToRelease).release()
        }

        connectionState = .idle
    }

    func reconnectManually() {
        isStoppedByUser = false
        reconnectAttempt = 0
        forceIPv4RetryOnce = false
        reconnectTask?.cancel()
        iceConnectWatchdogTask?.cancel()
        iceConnectWatchdogTask = nil
        disconnectWatchdogTask?.cancel()
        teardownRustHandleOnly()
        videoRenderer.resetForReconnect()
        audioEngine.start(sampleRate: 48_000, channels: settings.stereoAudio ? 2 : 1)
        gamepadManager.haptics.prepareForStream()
        Task {
            await connectOnce(forceTokenRefresh: true)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        audioEngine.setMuted(isMuted)
    }

    func toggleMicrophone() {
        micEngine.echoCancellationEnabled = settings.micEchoCancellation
        if isMicEnabled {
            micEngine.stop()
            isMicEnabled = false
            micLevel = 0
            audioEngine.ensureRunning(sampleRate: 48_000, channels: settings.stereoAudio ? 2 : 1)
            showToast("麦克风已关闭")
        } else {
            micEngine.requestPermissionAndStart { [weak self] ok, errMsg in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if ok {
                        self.isMicEnabled = true
                        self.audioEngine.ensureRunning(sampleRate: 48_000, channels: self.settings.stereoAudio ? 2 : 1)
                        let aecNote = self.settings.micEchoCancellation ? "· AEC 回声消除" : ""
                        self.showToast("语音开麦已开启（支持派对/联机\(aecNote)）")
                    } else {
                        self.isMicEnabled = false
                        self.showToast(errMsg ?? "无法启动麦克风")
                    }
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            videoRenderer.setDecodedFrameTap(nil)
            audioEngine.setPCMTap(nil)
            isRecording = false
            recordingElapsedSec = 0
            recorder.stop { [weak self] _, message in
                Task { @MainActor [weak self] in
                    self?.showToast(message)
                }
            }
        } else {
            let rec = recorder
            rec.start { [weak self] ok, message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if ok {
                        self.isRecording = true
                        self.recordingElapsedSec = 0
                        self.videoRenderer.setDecodedFrameTap { pb in
                            rec.appendVideoFrame(pb)
                        }
                        self.audioEngine.setPCMTap { samples, frameCount, sr, ch in
                            rec.appendAudioPCM(samples, frameCount: frameCount, sampleRate: sr, channels: ch)
                        }
                        self.recordingTimerTask?.cancel()
                        self.recordingTimerTask = Task { [weak self] in
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                guard let self, !Task.isCancelled, self.isRecording else { return }
                                self.recordingElapsedSec += 1
                            }
                        }
                        self.showToast(message)
                    } else {
                        self.showToast(message)
                    }
                }
            }
        }
    }

    private func stopRecordingSilently() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        videoRenderer.setDecodedFrameTap(nil)
        audioEngine.setPCMTap(nil)
        isRecording = false
        recordingElapsedSec = 0
        recorder.stop { _, _ in }
    }

    func saveInstantReplay() {
        guard !isSavingReplay else { return }
        isSavingReplay = true
        showToast("正在导出过去 30 秒原画精彩回放...")
        replayBuffer.exportLast30Seconds { [weak self] _, message in
            Task { @MainActor [weak self] in
                self?.isSavingReplay = false
                self?.showToast(message)
            }
        }
    }

    private func notifyStreamReadyInBackground() {
        let content = UNMutableNotificationContent()
        content.title = "XboxPad 串流已就绪"
        content.body = "「\(target.displayTitle)」已完成排队并进入游戏画面，点击立即开玩！"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "xboxpad.stream.ready.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    func captureScreenshotToPhotos(onCaptured: @escaping @MainActor (Bool) -> Void) {
        videoRenderer.captureCurrentFrameImage { [weak self] cgImage in
            guard let cgImage else {
                Task { @MainActor [weak self] in
                    self?.showToast("当前暂无可截取的视频帧")
                    onCaptured(false)
                }
                return
            }
            XboxPlatform.savePNGScreenshot(cgImage) { success, message in
                Task { @MainActor [weak self] in
                    self?.showToast(message)
                    onCaptured(success)
                }
            }
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        gamepadManager.settings = newSettings
        videoRenderer.updateFramePacingMode(newSettings.framePacingMode)
        videoRenderer.updateFrameInterpolation(newSettings.frameInterpolation120Hz)
        videoRenderer.updateSharpeningLevel(newSettings.sharpeningLevel)
        videoRenderer.updateHDRToneMode(newSettings.hdrToneMode)
        videoRenderer.updateDebanding(newSettings.debandingEnabled)
        videoRenderer.updateMetalFX(newSettings.metalFXUpscaling)
        videoRenderer.updateColorGrading(
            shadowLift: newSettings.shadowLift,
            brightness: newSettings.videoBrightness,
            contrast: newSettings.videoContrast,
            saturation: newSettings.videoSaturation
        )
        videoRenderer.updateZoomScale(newSettings.videoZoomScale)
        replayBuffer.setEnabled(newSettings.instantReplayEnabled)
        micEngine.echoCancellationEnabled = newSettings.micEchoCancellation
        syncThermalProtection()
        audioEngine.setPacingMode(newSettings.framePacingMode)
    }

    private func syncThermalProtection() {
        let state = ProcessInfo.processInfo.thermalState
        thermalState = state
        guard settings.thermalProtectionEnabled else {
            videoRenderer.updateThermalEDRMultiplier(1.0)
            return
        }
        switch state {
        case .nominal, .fair:
            videoRenderer.updateThermalEDRMultiplier(1.0)
        case .serious:
            videoRenderer.updateThermalEDRMultiplier(0.75)
        case .critical:
            videoRenderer.updateThermalEDRMultiplier(0.50)
        @unknown default:
            videoRenderer.updateThermalEDRMultiplier(1.0)
        }
    }

    func requestKeyframe() {
        handleBox.requestKeyframe()
    }

    // MARK: - Connection & Reconnect Lifecycle

    private func connectOnce(forceTokenRefresh: Bool) async {
        guard !isStoppedByUser else { return }
        videoRenderer.markAwaitingFirstFrame()
        connectionState = reconnectAttempt == 0
            ? .connecting("正在获取 Xbox 串流授权...")
            : .reconnecting(reconnectAttempt, "正在重新连接 (\(reconnectAttempt)/\(maxReconnectAttempts))...")

        do {
            let snapshot = try await authService.getValidSessionSnapshot(
                forceRefresh: forceTokenRefresh,
                forceRegionIP: settings.forceRegionIP,
                requireCloud: !target.isHome
            )
            let transferToken = try await authService.fetchConnectTransferToken(
                forceRegionIP: settings.forceRegionIP
            )
            guard !isStoppedByUser else { return }

            let tokenBundle: StreamingTokenBundle
            let preferredRegion: String
            switch target {
            case .home:
                tokenBundle = snapshot.xHomeToken
                preferredRegion = settings.selectedHomeRegion
            case .cloud:
                guard let cloudToken = snapshot.xCloudToken else {
                    connectionState = .failed("当前账号或地区未获取到 xCloud 云游戏凭证，可在云游戏页右上角切换日本/韩国/美国节点后重试。")
                    return
                }
                tokenBundle = cloudToken
                preferredRegion = settings.selectedCloudRegion
            }

            let baseUri = tokenBundle.resolvedBaseUri(preferredRegionName: preferredRegion)
            guard !baseUri.isEmpty else {
                connectionState = .failed("未找到可用的串流区域服务器地址。")
                return
            }

            let effectiveCloudIP = target.isHome
                ? ""
                : (tokenBundle.resolvedRegionIP ?? settings.forceRegionIP)
            launchRustEngine(
                baseUri: baseUri,
                gsToken: tokenBundle.gsToken,
                connectUserToken: transferToken,
                forceRegionIP: effectiveCloudIP
            )
        } catch {
            guard !isStoppedByUser else { return }
            handleTerminalFailure(message: error.localizedDescription)
        }
    }

    private func launchRustEngine(
        baseUri: String,
        gsToken: String,
        connectUserToken: String,
        forceRegionIP: String
    ) {
        teardownRustHandleOnly()

        let retainedSelf = Unmanaged.passRetained(self).toOpaque()
        callbackContext = retainedSelf

        let callbacks = XboxPadCallbacks(
            user_data: retainedSelf,
            on_video_frame: { userData, ptr, len, ptsUs, keyframe in
                guard let userData, let ptr, len > 0 else { return }
                let session = Unmanaged<NanoStreamSession>.fromOpaque(userData).takeUnretainedValue()
                let data = Data(bytes: ptr, count: len)
                session.replayBuffer.appendVideo(data: data, ptsUs: ptsUs, keyframe: keyframe)
                session.videoRenderer.enqueueAccessUnit(data: data, ptsUs: ptsUs, keyframe: keyframe)
            },
            on_audio_frame: { userData, ptr, len, _, sampleRate, channels in
                guard let userData, let ptr, len > 0 else { return }
                let session = Unmanaged<NanoStreamSession>.fromOpaque(userData).takeUnretainedValue()
                let data = Data(bytes: ptr, count: len)
                session.replayBuffer.appendAudio(data: data, sampleRate: sampleRate, channels: channels)
                session.audioEngine.enqueueOpusFrame(data: data, sampleRate: sampleRate, channels: channels)
            },
            on_status: { userData, stagePtr, msgPtr, terminal in
                guard let userData else { return }
                let session = Unmanaged<NanoStreamSession>.fromOpaque(userData).takeUnretainedValue()
                let stage = stagePtr.map { String(cString: $0) } ?? ""
                let msg = msgPtr.map { String(cString: $0) } ?? ""
                Task { @MainActor in
                    session.handleRustStatus(stage: stage, message: msg, terminal: terminal)
                }
            },
            on_stats: { userData, statsPtr in
                guard let userData, let statsPtr else { return }
                let session = Unmanaged<NanoStreamSession>.fromOpaque(userData).takeUnretainedValue()
                let s = statsPtr.pointee
                let decodeMs = session.latestDecodeMs
                let audioMs = session.audioEngine.bufferedDurationMs
                Task { @MainActor in
                    let prevFrames = session.stats.framesReceived
                    if s.frames_received > prevFrames {
                        session.lastVideoFrameTimestamp = CACurrentMediaTime()
                        session.stallSoftRecovered = false
                    }
                    session.stats = LiveStreamStats(
                        rttMs: s.rtt_ms,
                        jitterMs: s.jitter_ms,
                        fps: s.fps,
                        bitrateMbps: s.bitrate_mbps,
                        packetLossPct: s.packet_loss_pct,
                        framesDropped: s.frames_dropped,
                        framesReceived: s.frames_received,
                        decodeMs: decodeMs,
                        audioBufferMs: audioMs,
                        routeKind: s.route_kind
                    )
                    let pipeMsNow = session.videoRenderer.latestPipelineLatencyMs
                    if s.rtt_ms >= 0 || pipeMsNow > 0 {
                        session.latencySampleSeq += 1
                        session.latencyHistory.append(
                            LatencySample(
                                id: session.latencySampleSeq,
                                rttMs: max(s.rtt_ms, 0),
                                pipeMs: max(pipeMsNow, 0)
                            )
                        )
                        if session.latencyHistory.count > 30 {
                            session.latencyHistory.removeFirst(session.latencyHistory.count - 30)
                        }
                    }
                    session.statsLogTick += 1
                    if session.statsLogTick % 3 == 0 {
                        let dispFps = session.videoRenderer.measuredDisplayFps
                        let pipeMs = session.videoRenderer.latestPipelineLatencyMs
                        nanoLogger.info(
                            "stats route=\(session.stats.routeBadgeText, privacy: .public) fps=\(String(format: "%.1f", s.fps), privacy: .public) dispFps=\(String(format: "%.1f", dispFps), privacy: .public) pipeMs=\(String(format: "%.1f", pipeMs), privacy: .public) rttMs=\(String(format: "%.1f", s.rtt_ms), privacy: .public) mbps=\(String(format: "%.2f", s.bitrate_mbps), privacy: .public) lossPct=\(String(format: "%.2f", s.packet_loss_pct), privacy: .public) droppedFrames=\(s.frames_dropped, privacy: .public) decodeMs=\(String(format: "%.1f", decodeMs), privacy: .public) audioBufMs=\(String(format: "%.0f", audioMs), privacy: .public)"
                        )
                    }
                }
            },
            on_rumble: { userData, rumblePtr in
                guard let userData, let rumblePtr else { return }
                let session = Unmanaged<NanoStreamSession>.fromOpaque(userData).takeUnretainedValue()
                let r = rumblePtr.pointee
                session.gamepadManager.haptics.applyRumble(
                    gamepadIndex: r.gamepad_index,
                    startDelayMs: r.start_delay_ms,
                    durationMs: r.duration_ms,
                    delayMs: r.delay_ms,
                    repeatCount: r.repeat,
                    strongMagnitude: r.strong_magnitude,
                    weakMagnitude: r.weak_magnitude,
                    leftTrigger: r.left_trigger,
                    rightTrigger: r.right_trigger
                )
            }
        )

        guard let handle = xboxpad_create(callbacks) else {
            Unmanaged<NanoStreamSession>.fromOpaque(retainedSelf).release()
            callbackContext = nil
            handleTerminalFailure(message: "无法初始化底层 Rust 串流引擎。")
            return
        }
        handleBox.set(handle)

        let sessionId = target.sessionId
        let streamType = target.streamType
        let lang = settings.preferredLanguage
        let trimmedCustomIce = settings.customIceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let iceUrl: String
        let iceUser: String
        let icePass: String
        if !trimmedCustomIce.isEmpty {
            iceUrl = trimmedCustomIce
            iceUser = settings.customIceUser
            icePass = settings.customIcePass
        } else if settings.useBuiltInRelay && xboxpad_has_builtin_ice() {
            iceUrl = "builtin"
            iceUser = ""
            icePass = ""
        } else {
            iceUrl = "off"
            iceUser = ""
            icePass = ""
        }
        let resolution = Int32(settings.resolution.rawValue)
        let stereo = settings.stereoAudio
        let coopEnabled = gamepadManager.connectedControllers.count > 1
        let effectiveNetworkMode: UInt8 = (forceIPv4RetryOnce && settings.networkMode == .auto)
            ? UInt8(StreamNetworkMode.ipv4Only.rawValue)
            : UInt8(settings.networkMode.rawValue)
        if forceIPv4RetryOnce && settings.networkMode == .auto {
            nanoLogger.info("ICE fallback retry active: forcing IPv4-only STUN/TURN mode for this attempt")
        }
        let networkMode = effectiveNetworkMode
        let maxDelay = UInt32(settings.latencyProfile.rawValue)
        let maxBitrateKbps = UInt32(max(settings.customMaxBitrateMbps, 0) * 1000)

        let rc: Int32 = sessionId.withCString { cSessionId in
            streamType.withCString { cStreamType in
                baseUri.withCString { cBaseUri in
                    gsToken.withCString { cGsToken in
                        connectUserToken.withCString { cTransfer in
                            lang.withCString { cLang in
                                iceUrl.withCString { cIceUrl in
                                    iceUser.withCString { cIceUser in
                                        icePass.withCString { cIcePass in
                                            forceRegionIP.withCString { cRegionIP in
                                                var cfg = XboxPadConfig(
                                                    session_id: cSessionId,
                                                    stream_type: cStreamType,
                                                    base_uri: cBaseUri,
                                                    gs_token: cGsToken,
                                                    connect_user_token: cTransfer,
                                                    resolution: resolution,
                                                    preferred_language: cLang,
                                                    ice_server_url: cIceUrl,
                                                    ice_server_username: cIceUser,
                                                    ice_server_credential: cIcePass,
                                                    stereo_audio_enabled: stereo,
                                                    coop: coopEnabled,
                                                    network_mode: networkMode,
                                                    max_video_delay_ms: maxDelay,
                                                    force_region_ip: cRegionIP,
                                                    max_video_bitrate_kbps: maxBitrateKbps
                                                )
                                                return xboxpad_start(handle, &cfg)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if rc != 0 {
            handleTerminalFailure(message: "启动串流会话失败 (错误码 \(rc))")
        }
    }

    private func teardownRustHandleOnly() {
        iceConnectWatchdogTask?.cancel()
        iceConnectWatchdogTask = nil
        let oldHandle = handleBox.take()
        let oldCtx = callbackContext
        callbackContext = nil
        if let oldHandle {
            let box = DestroyBox(handle: oldHandle, ctx: oldCtx)
            DispatchQueue.global(qos: .userInitiated).async {
                xboxpad_destroy(box.handle)
                if let ctx = box.ctx {
                    Unmanaged<NanoStreamSession>.fromOpaque(ctx).release()
                }
            }
        } else if let oldCtx {
            Unmanaged<NanoStreamSession>.fromOpaque(oldCtx).release()
        }
    }

    private func handleRustStatus(stage: String, message: String, terminal: Bool) {
        guard !isStoppedByUser else { return }

        if stage == "ice-exchanged" {
            if case .streaming = connectionState { return }
            connectionState = .connecting(message.isEmpty ? "已交换 ICE 候选，正在穿透建立连接..." : message)
            iceConnectWatchdogTask?.cancel()
            iceConnectWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                guard let self, !Task.isCancelled, !self.isStoppedByUser else { return }
                if case .streaming = self.connectionState { return }
                nanoLogger.warning("ICE connect watchdog fired after 14s at ice-exchanged")
                if self.settings.networkMode == .auto && !self.forceIPv4RetryOnce {
                    self.forceIPv4RetryOnce = true
                }
                self.handleTerminalFailure(
                    message: "ICE 穿透超时（外网 NAT/防火墙阻断直连），请确认已开启内置中继或切换至「仅 IPv4」模式"
                )
            }
            return
        }

        if stage == "connected" {
            disconnectWatchdogTask?.cancel()
            if case .streaming = connectionState { return }
            videoRenderer.markAwaitingFirstFrame()
            connectionState = .connecting("通道已就绪，正在等待首帧画面...")
            requestKeyframe()
            iceConnectWatchdogTask?.cancel()
            iceConnectWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, !self.isStoppedByUser else { return }
                if case .streaming = self.connectionState { return }
                nanoLogger.info("awaiting first frame (3s) -> nudging keyframe/PLI")
                self.requestKeyframe()

                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !self.isStoppedByUser else { return }
                if case .streaming = self.connectionState { return }
                nanoLogger.info("awaiting first frame (6s) -> nudging keyframe/PLI")
                self.requestKeyframe()

                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, !self.isStoppedByUser else { return }
                if case .streaming = self.connectionState { return }
                nanoLogger.warning("first frame watchdog fired after 10s at connected")
                self.handleTerminalFailure(message: "连接已建立但长时间未收到视频首帧，正在重连...")
            }
            return
        }

        if stage == "disconnected" {
            iceConnectWatchdogTask?.cancel()
            iceConnectWatchdogTask = nil
            videoRenderer.markAwaitingFirstFrame()
            connectionState = .connecting("网络短暂波动，正在恢复...")
            disconnectWatchdogTask?.cancel()
            disconnectWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !Task.isCancelled, !self.isStoppedByUser else { return }
                self.handleTerminalFailure(message: "网络连接持续中断超过 6 秒")
            }
            return
        }

        if terminal || stage == "failed" || stage == "closed" {
            iceConnectWatchdogTask?.cancel()
            iceConnectWatchdogTask = nil
            handleTerminalFailure(message: message.isEmpty ? "串流会话已断开" : message)
            return
        }

        if case .streaming = connectionState {
            return
        }
        connectionState = .connecting(message.isEmpty ? stage : message)
    }

    private func handleTerminalFailure(message: String) {
        guard !isStoppedByUser else { return }
        iceConnectWatchdogTask?.cancel()
        iceConnectWatchdogTask = nil
        disconnectWatchdogTask?.cancel()
        gamepadManager.haptics.stopAll()

        let lowerMsg = message.lowercased()
        let isWnsWakeFailure = target.isHome
            && (lowerMsg.contains("errorcallingwns") || lowerMsg.contains("waitingforservertoregister"))
        if isWnsWakeFailure {
            // Bypass cloud WNS outage by blasting local LAN SmartGlass UDP 5050 Power-On + XCCS WakeUp
            XboxHomeAPI.sendLocalSmartGlassWakeUp(liveId: target.sessionId)
            Task { [authService, target, settings] in
                if let snapshot = try? await authService.getValidSessionSnapshot(
                    forceRefresh: false,
                    forceRegionIP: settings.forceRegionIP
                ) {
                    try? await XboxHomeAPI.sendPowerCommand(
                        consoleId: target.sessionId,
                        wakeUp: true,
                        webToken: snapshot.webToken
                    )
                }
            }
        }

        let displayMessage: String = isWnsWakeFailure
            ? "微软云端 WNS 唤醒主机失败（主机可能已关机或待机假死），已自动补发局域网 UDP 5050 唤醒包。若持续失败，请确认 Xbox 电源模式为「睡眠」或重启主机。"
            : message

        if settings.autoReconnect && reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            let delaySec = isWnsWakeFailure ? min(4.0 * Double(reconnectAttempt), 10.0) : min(1.5 * Double(reconnectAttempt), 5.0)
            connectionState = .reconnecting(
                reconnectAttempt,
                "\(displayMessage)\n\(Int(delaySec.rounded())) 秒后自动重连 (\(reconnectAttempt)/\(maxReconnectAttempts))..."
            )
            teardownRustHandleOnly()
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.isStoppedByUser else { return }
                self.videoRenderer.resetForReconnect()
                await self.connectOnce(forceTokenRefresh: self.reconnectAttempt >= 2)
            }
        } else {
            connectionState = .failed(displayMessage)
        }
    }

    private func setupLifecycleObservers() {
        #if os(iOS)
        let fgName = UIApplication.willEnterForegroundNotification
        let bgName = UIApplication.didEnterBackgroundNotification
        #elseif os(macOS)
        let fgName = NSApplication.didUnhideNotification
        let bgName = NSApplication.didHideNotification
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: fgName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStoppedByUser else { return }
                self.isAppInBackground = false
                self.lastVideoFrameTimestamp = CACurrentMediaTime()
                self.stallSoftRecovered = false
                self.videoRenderer.resetForForeground()
                self.audioEngine.ensureRunning(sampleRate: 48_000, channels: self.settings.stereoAudio ? 2 : 1)
                self.requestKeyframe()
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: bgName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isAppInBackground = true
                self.gamepadManager.haptics.stopAll()
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncThermalProtection()
            }
        }
    }

    /// Detects silent UDP blackholes where WebRTC stays `Connected` while video stops flowing:
    /// - 2.5s stall -> soft keyframe/PLI recovery without dropping the session
    /// - 6.5s stall -> automatic seamless reconnect
    private func startStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, !self.isStoppedByUser else { return }
                guard !self.isAppInBackground, case .streaming = self.connectionState else { continue }
                guard self.lastVideoFrameTimestamp > 0 else { continue }

                let stalledSec = CACurrentMediaTime() - self.lastVideoFrameTimestamp
                if stalledSec >= 2.5 && !self.stallSoftRecovered {
                    self.stallSoftRecovered = true
                    nanoLogger.warning("video stall detected (\(String(format: "%.1f", stalledSec), privacy: .public)s) -> requesting recovery keyframe")
                    self.requestKeyframe()
                } else if stalledSec >= 6.5 {
                    nanoLogger.warning("video stall exceeded 6.5s -> triggering auto-reconnect")
                    self.stallWatchdogTask?.cancel()
                    self.handleTerminalFailure(message: "视频流长时间无响应（网络切换或波动）")
                    return
                }
            }
        }
    }

    /// Monitors iPadOS / iOS network path switches (Wi-Fi <-> 5G / AP handoff) to recover faster
    /// instead of waiting 11+ seconds for an ICE timeout on a dead interface.
    private func startNetworkPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let sig = Self.networkSignature(for: path)
            Task { @MainActor [weak self] in
                guard let self, !self.isStoppedByUser else { return }
                if self.lastNetworkSignature == nil {
                    self.lastNetworkSignature = sig
                    return
                }
                guard sig != self.lastNetworkSignature else { return }
                let oldSig = self.lastNetworkSignature ?? ""
                self.lastNetworkSignature = sig
                nanoLogger.info("network path changed \(oldSig, privacy: .public) -> \(sig, privacy: .public)")

                if path.status == .satisfied, case .streaming = self.connectionState {
                    // Interface switched (e.g. Wi-Fi <-> 5G): trigger quick clean reconnect
                    if self.settings.autoReconnect {
                        self.handleTerminalFailure(message: "检测到网络切换，正在快速重连")
                    }
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private nonisolated static func networkSignature(for path: NWPath) -> String {
        let iface: String
        if path.usesInterfaceType(.wiredEthernet) {
            iface = "eth"
        } else if path.usesInterfaceType(.wifi) {
            iface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            iface = "cell"
        } else {
            iface = "other"
        }
        let status = path.status == .satisfied ? "up" : "down"
        return "\(status):\(iface)"
    }
}
