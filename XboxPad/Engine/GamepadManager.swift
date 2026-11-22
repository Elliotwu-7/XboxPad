#if os(iOS)
import CoreMotion
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Combine
import Foundation
import GameController
import os
import QuartzCore
import XboxPadNanoFFI

enum GamepadMenuAction: Sendable {
    case up
    case down
    case left
    case right
    case confirm
    case back
    case prevTab
    case nextTab
}

/// Native iPadOS multi-controller + keyboard/mouse manager:
/// - Supports up to 4 simultaneous hardware controllers (`P1`–`P4`, `gamepad_index = 0..3`)
/// - Identifies exact controller models (Xbox Series X|S, Xbox Elite 2, Xbox One, PS5 DualSense,
///   PS4 DualShock 4, Switch Pro, Joy-Con, Backbone, 8BitDo, GameSir, etc.) + battery % & charging state
/// - Supports hardware Keyboard (`GCKeyboard`) & Mouse (`GCMouse`) in BOTH:
///   1) Gamepad Emulation Mode (works on 100% of Xbox console & cloud games: WASD + mouse look)
///   2) Native Xbox K&M Wire Mode (for K&M-enabled xCloud games)
/// - Zero-hop `.userInteractive` 120Hz input queue dispatching straight to Rust FFI
/// - Triple-layer Home button capture (`GCControllerLiveInput`, `GCInputButtonHome`, `buttonHome`)
@MainActor
final class GamepadManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "gamepad")

    @Published private(set) var telemetry = GamepadTelemetry()
    @Published private(set) var activeController: GCController?
    @Published private(set) var connectedControllers: [GCController] = []
    @Published var selectedSlotIndex: Int = 0 {
        didSet {
            if selectedSlotIndex < connectedControllers.count {
                let target = connectedControllers[selectedSlotIndex]
                activeController = target
                refreshTelemetrySnapshot()
            }
        }
    }

    let haptics = HapticsEngine()

    var settings = AppSettings() {
        didSet {
            haptics.updateSettings(settings)
            syncRuntimeConfig()
            syncGyroSensors()
        }
    }

    /// Thread-safe callbacks invoked directly on `inputQueue`.
    var onInputFrame: (@Sendable (XboxPadInputFrame) -> Void)? {
        didSet {
            let cb = onInputFrame
            inputQueue.async { [runtime] in
                runtime.onInputFrame = cb
            }
        }
    }

    var onGamepadSlotChanged: (@Sendable (UInt8, Bool) -> Void)? {
        didSet {
            let cb = onGamepadSlotChanged
            inputQueue.async { [runtime] in
                runtime.onGamepadSlotChanged = cb
            }
        }
    }

    var onMouseEvent: (@Sendable (Int32, Int32, Int32, Int32, UInt8, UInt8) -> Void)? {
        didSet {
            let cb = onMouseEvent
            inputQueue.async { [runtime] in
                runtime.onMouseEvent = cb
            }
        }
    }

    var onKeyboardEvent: (@Sendable (UInt8, Bool) -> Void)? {
        didSet {
            let cb = onKeyboardEvent
            inputQueue.async { [runtime] in
                runtime.onKeyboardEvent = cb
            }
        }
    }

    /// Invoked on MainActor when user holds View + Menu together to toggle stream overlay.
    var onToggleOverlayRequested: (() -> Void)?

    /// Broadcasts non-streaming Couch Mode UI navigation events (D-pad / Stick / A / B / LB / RB)
    /// so RootView, HomeConsolesView, and CloudGamesView can all react cleanly.
    let menuNavigationPublisher = PassthroughSubject<GamepadMenuAction, Never>()

    private let inputQueue = DispatchQueue(label: "com.elliot.xboxpad.gamepad.input", qos: .userInteractive)
    #if os(iOS)
    private let motionManager = CMMotionManager()
    #endif
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.elliot.xboxpad.gyro"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var isStreaming = false

    private final class InputRuntime: @unchecked Sendable {
        var controllers: [GCController] = [] // P1..P4 (max 4)
        var lastFrames: [XboxPadInputFrame] = Array(repeating: XboxPadInputFrame(), count: 4)
        var connectedSlotMask: UInt8 = 0
        var isStreamingActive = false
        var leftDeadzone: Float = 0.05
        var rightDeadzone: Float = 0.05
        var responseExponent: Float = 1.0
        var triggerDeadzone: Float = 0.02
        var gyroMode: GyroAimMode = .off
        var gyroSensitivity: Float = 1.0
        var gyroInvertY: Bool = false
        var deviceGyroX: Float = 0
        var deviceGyroY: Float = 0
        var kmMode: KeyboardMouseMode = .gamepadEmulation
        var mouseSensitivity: Float = 1.5
        var mouseAntiDeadzone: Float = 0.18
        var mouseYScale: Float = 0.85
        var mouseInvertY: Bool = false
        var pendingMouseDX: Float = 0
        var pendingMouseDY: Float = 0
        var mouseSmoothX: Float = 0
        var mouseSmoothY: Float = 0
        var lastMouseMoveTime: CFTimeInterval = 0
        var nativeMouseFracX: Float = 0
        var nativeMouseFracY: Float = 0
        var mouseVelX: Float = 0
        var mouseVelY: Float = 0
        var mouseButtonsMask: UInt8 = 0 // bit0=LMB, bit1=RMB, bit2=MMB, bit3=Side1, bit4=Side2
        var scrollPulseKind: UInt8 = 0 // 1=dpadUp, 2=dpadDown, 3=dpadLeft, 4=dpadRight, 5=LB, 6=RB
        var scrollPulseUntil: CFTimeInterval = 0
        var arrowStickX: Float = 0
        var arrowStickY: Float = 0
        var pressedKeys: Set<GCKeyCode> = []
        var mapShareToNexus = true
        var menuComboEnabled = true
        var nintendoLayout: NintendoButtonLayoutMode = .auto
        var isNintendoSlot: [Bool] = [false, false, false, false]
        var buttonMap = GamepadButtonMap()
        var keyBindings = KeyboardBindingMap()
        var virtualOverrides = XboxPadInputFrame()
        var virtualLeftX: Float = 0
        var virtualLeftY: Float = 0
        var virtualRightX: Float = 0
        var virtualRightY: Float = 0
        var virtualLeftTrigger: Float = 0
        var virtualRightTrigger: Float = 0
        var hasVirtualInput = false
        var comboStartTime: CFTimeInterval = 0
        var comboFiredForCurrentHold = false
        var pollTimer: DispatchSourceTimer?
        var onInputFrame: (@Sendable (XboxPadInputFrame) -> Void)?
        var onGamepadSlotChanged: (@Sendable (UInt8, Bool) -> Void)?
        var onMouseEvent: (@Sendable (Int32, Int32, Int32, Int32, UInt8, UInt8) -> Void)?
        var onKeyboardEvent: (@Sendable (UInt8, Bool) -> Void)?
        var onComboTriggered: (@Sendable () -> Void)?
        var onNonStreamingUpdate: (@Sendable () -> Void)?
        var onMenuAction: (@Sendable (GamepadMenuAction) -> Void)?
        var lastTelemetryPush: CFTimeInterval = 0
        var lastMenuDirTime: CFTimeInterval = 0
        var lastMenuButtonsMask: UInt8 = 0
    }

    private let runtime = InputRuntime()
    private var observers: [NSObjectProtocol] = []

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        runtime.onComboTriggered = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.haptics.playSubtleConfirmPulse()
                self.onToggleOverlayRequested?()
            }
        }
        runtime.onNonStreamingUpdate = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshTelemetrySnapshot()
            }
        }
        runtime.onMenuAction = { [weak self] action in
            Task { @MainActor [weak self] in
                self?.menuNavigationPublisher.send(action)
            }
        }
        startObservingHardware()
        refreshConnectedDevices()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        #if os(iOS)
        motionManager.stopDeviceMotionUpdates()
        #endif
        runtime.pollTimer?.cancel()
    }

    private func syncRuntimeConfig() {
        let ldz = Float(settings.leftStickDeadzone)
        let rdz = Float(settings.rightStickDeadzone)
        let exp = settings.stickResponseCurve.exponent
        let tdz = Float(settings.triggerDeadzone)
        let gMode = settings.gyroAimMode
        let gSens = Float(settings.gyroSensitivity)
        let gInv = settings.gyroInvertY
        let kmMode = settings.keyboardMouseMode
        let mSens = Float(settings.mouseSensitivity)
        let mAntiDZ = Float(settings.mouseAntiDeadzone)
        let mYScale = Float(settings.mouseYScale)
        let mInvY = settings.mouseInvertY
        let share = settings.mapShareToNexus
        let combo = settings.menuComboEnabled
        let ninLayout = settings.nintendoButtonLayout
        let bMap = settings.gamepadButtonMap
        let kBind = settings.keyboardBindingMap
        inputQueue.async { [runtime] in
            runtime.leftDeadzone = ldz
            runtime.rightDeadzone = rdz
            runtime.responseExponent = exp
            runtime.triggerDeadzone = tdz
            runtime.gyroMode = gMode
            runtime.gyroSensitivity = gSens
            runtime.gyroInvertY = gInv
            runtime.kmMode = kmMode
            runtime.mouseSensitivity = mSens
            runtime.mouseAntiDeadzone = mAntiDZ
            runtime.mouseYScale = mYScale
            runtime.mouseInvertY = mInvY
            runtime.mapShareToNexus = share
            runtime.menuComboEnabled = combo
            runtime.nintendoLayout = ninLayout
            runtime.buttonMap = bMap
            runtime.keyBindings = kBind
            if gMode == .off {
                runtime.deviceGyroX = 0
                runtime.deviceGyroY = 0
            }
            if kmMode == .off {
                runtime.pendingMouseDX = 0
                runtime.pendingMouseDY = 0
                runtime.mouseSmoothX = 0
                runtime.mouseSmoothY = 0
                runtime.nativeMouseFracX = 0
                runtime.nativeMouseFracY = 0
                runtime.mouseVelX = 0
                runtime.mouseVelY = 0
                runtime.mouseButtonsMask = 0
                runtime.scrollPulseKind = 0
                runtime.scrollPulseUntil = 0
                runtime.arrowStickX = 0
                runtime.arrowStickY = 0
                runtime.pressedKeys.removeAll(keepingCapacity: true)
            }
        }
    }

    private func syncGyroSensors() {
        let wantsGyro = isStreaming && settings.gyroAimMode != .off
        if let primary = connectedControllers.first, let motion = primary.motion {
            motion.sensorsActive = wantsGyro
            #if os(iOS)
            if motionManager.isDeviceMotionActive {
                motionManager.stopDeviceMotionUpdates()
            }
            #endif
            return
        }

        #if os(iOS)
        if wantsGyro && motionManager.isDeviceMotionAvailable {
            if !motionManager.isDeviceMotionActive {
                motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
                motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                    guard let self, let motion else { return }
                    let rate = motion.rotationRate
                    let rawYaw = Float(-rate.y)
                    let rawPitch = Float(rate.x)
                    self.inputQueue.async { [runtime = self.runtime] in
                        runtime.deviceGyroX = rawYaw
                        runtime.deviceGyroY = rawPitch
                    }
                }
            }
        } else if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
            inputQueue.async { [runtime] in
                runtime.deviceGyroX = 0
                runtime.deviceGyroY = 0
            }
        }
        #endif
    }

    func setStreamingActive(_ active: Bool) {
        isStreaming = active
        if active {
            for c in connectedControllers {
                disableSystemGestures(on: c)
            }
        }
        syncGyroSensors()
        let queue = inputQueue
        inputQueue.async { [runtime] in
            runtime.isStreamingActive = active
            if active {
                Self.startHighFrequencyPollingLocked(runtime: runtime, queue: queue)
                Self.sendAllSlotsLocked(runtime: runtime, force: true)
            } else {
                runtime.pollTimer?.cancel()
                runtime.pollTimer = nil
                runtime.virtualOverrides = XboxPadInputFrame()
                runtime.virtualLeftX = 0
                runtime.virtualLeftY = 0
                runtime.virtualRightX = 0
                runtime.virtualRightY = 0
                runtime.virtualLeftTrigger = 0
                runtime.virtualRightTrigger = 0
                runtime.hasVirtualInput = false
                runtime.deviceGyroX = 0
                runtime.deviceGyroY = 0
                runtime.pendingMouseDX = 0
                runtime.pendingMouseDY = 0
                runtime.mouseSmoothX = 0
                runtime.mouseSmoothY = 0
                runtime.nativeMouseFracX = 0
                runtime.nativeMouseFracY = 0
                runtime.mouseVelX = 0
                runtime.mouseVelY = 0
                runtime.mouseButtonsMask = 0
                runtime.scrollPulseKind = 0
                runtime.scrollPulseUntil = 0
                runtime.arrowStickX = 0
                runtime.arrowStickY = 0
                runtime.pressedKeys.removeAll(keepingCapacity: true)
            }
        }
        if !active {
            haptics.stopAll()
        }
    }

    // MARK: - Virtual Touch Controls (P1 slot)

    func setVirtualButton(_ keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>, pressed: Bool) {
        let val: UInt8 = pressed ? 1 : 0
        inputQueue.async { [runtime] in
            runtime.virtualOverrides[keyPath: keyPath] = val
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
    }

    func setVirtualLeftStick(x: Float, y: Float) {
        let cx = max(-1.0, min(1.0, x))
        let cy = max(-1.0, min(1.0, y))
        inputQueue.async { [runtime] in
            runtime.virtualLeftX = cx
            runtime.virtualLeftY = cy
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
    }

    func setVirtualRightStick(x: Float, y: Float) {
        let cx = max(-1.0, min(1.0, x))
        let cy = max(-1.0, min(1.0, y))
        inputQueue.async { [runtime] in
            runtime.virtualRightX = cx
            runtime.virtualRightY = cy
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
    }

    func setVirtualLeftTrigger(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        inputQueue.async { [runtime] in
            runtime.virtualLeftTrigger = clamped
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
    }

    func setVirtualRightTrigger(_ value: Float) {
        let clamped = max(0.0, min(1.0, value))
        inputQueue.async { [runtime] in
            runtime.virtualRightTrigger = clamped
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
    }

    func pulseNexusButton() {
        holdNexusButton(durationMs: 140)
    }

    func holdNexusButton(durationMs: UInt64 = 1200) {
        inputQueue.async { [runtime] in
            runtime.virtualOverrides.nexus = 1
            runtime.hasVirtualInput = true
            Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            self.inputQueue.async { [runtime = self.runtime] in
                runtime.virtualOverrides.nexus = 0
                Self.sendSlotLocked(runtime: runtime, slot: 0, force: true)
            }
        }
    }

    // MARK: - Hardware Discovery (Multi-Controller + Keyboard + Mouse)

    private func startObservingHardware() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            .GCControllerDidConnect,
            .GCControllerDidDisconnect,
            .GCControllerDidBecomeCurrent,
            .GCKeyboardDidConnect,
            .GCKeyboardDidDisconnect,
            .GCMouseDidConnect,
            .GCMouseDidDisconnect,
        ]
        for name in names {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshConnectedDevices()
                    }
                }
            )
        }
        #if os(iOS)
        let activeNotificationName = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let activeNotificationName = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(
            nc.addObserver(forName: activeNotificationName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for controller in self.connectedControllers {
                        self.disableSystemGestures(on: controller)
                    }
                    self.refreshTelemetrySnapshot()
                }
            }
        )
    }

    private func disableSystemGestures(on controller: GCController) {
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        if #available(iOS 17.0, *), let liveHome = controller.input.buttons[.home] {
            liveHome.pressedInput.pressedDidChangeHandler = { [runtime] _, _, pressed in
                Self.logger.info("home button (liveInput) pressed=\(pressed, privacy: .public)")
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
        }
        if let physicalHome = controller.physicalInputProfile.buttons[GCInputButtonHome] {
            physicalHome.preferredSystemGestureState = .disabled
            physicalHome.pressedChangedHandler = { [runtime] _, _, pressed in
                Self.logger.info("home button (physicalProfile) pressed=\(pressed, privacy: .public)")
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
            physicalHome.valueChangedHandler = { [runtime] _, _, _ in
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
        }
        if let extHome = controller.extendedGamepad?.buttonHome {
            extHome.preferredSystemGestureState = .disabled
            extHome.pressedChangedHandler = { [runtime] _, _, pressed in
                Self.logger.info("home button (extendedGamepad) pressed=\(pressed, privacy: .public)")
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
            extHome.valueChangedHandler = { [runtime] _, _, _ in
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
        }
        if let shareBtn = controller.physicalInputProfile.buttons[GCInputButtonShare] {
            shareBtn.preferredSystemGestureState = .disabled
            shareBtn.pressedChangedHandler = { [runtime] _, _, _ in
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
            shareBtn.valueChangedHandler = { [runtime] _, _, _ in
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
        }
    }

    func selectBestController() {
        refreshConnectedDevices()
    }

    func refreshConnectedDevices() {
        let allPads = Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(4))
        connectedControllers = allPads

        let playerIndices: [GCControllerPlayerIndex] = [.index1, .index2, .index3, .index4]
        for (idx, controller) in allPads.enumerated() {
            controller.playerIndex = playerIndices[idx]
            controller.handlerQueue = inputQueue
            disableSystemGestures(on: controller)
            controller.extendedGamepad?.valueChangedHandler = { [runtime] _, _ in
                Self.handleGamepadChangeLocked(runtime: runtime)
            }
        }

        if allPads.isEmpty {
            selectedSlotIndex = 0
            activeController = nil
            haptics.bindControllers([], primarySlot: 0)
        } else {
            if selectedSlotIndex >= allPads.count {
                selectedSlotIndex = 0
            }
            let primary = allPads[selectedSlotIndex]
            activeController = primary
            haptics.bindControllers(allPads, primarySlot: selectedSlotIndex)
        }

        bindHardwareKeyboardAndMouse()

        var newMask: UInt8 = 0
        var nintendoFlags: [Bool] = [false, false, false, false]
        for idx in 0..<allPads.count {
            newMask |= (1 << idx)
            let c = allPads[idx]
            let v = (c.vendorName ?? "").lowercased()
            let cat = c.productCategory.lowercased()
            nintendoFlags[idx] = v.contains("nintendo")
                || v.contains("pro controller")
                || v.contains("joy-con")
                || cat.contains("nintendo")
                || cat.contains("switch")
                || cat.contains("joy-con")
        }
        let capturedPads = allPads
        let capturedNintendoFlags = nintendoFlags
        inputQueue.async { [runtime] in
            let prevMask = runtime.connectedSlotMask
            runtime.controllers = capturedPads
            runtime.connectedSlotMask = newMask
            runtime.isNintendoSlot = capturedNintendoFlags

            if runtime.isStreamingActive {
                // Dynamically notify Xbox when P2/P3/P4 connects or disconnects mid-stream
                for slot in 0..<4 {
                    let bit: UInt8 = 1 << slot
                    let wasOn = (prevMask & bit) != 0
                    let isOn = (newMask & bit) != 0
                    if wasOn != isOn {
                        if slot > 0 {
                            runtime.onGamepadSlotChanged?(UInt8(slot), isOn)
                        }
                        if !isOn {
                            var neutral = XboxPadInputFrame()
                            neutral.gamepad_index = UInt8(slot)
                            runtime.lastFrames[slot] = neutral
                            runtime.onInputFrame?(neutral)
                        }
                    }
                }
            }
        }

        syncGyroSensors()
        refreshTelemetrySnapshot()
    }

    // MARK: - Platform Mouse & Keyboard Direct Injection (macOS Pointer-Locked AppKit + Trackpad)

    /// Injects raw relative pointer movement (`dx > 0` right, `dy > 0` up) directly from macOS AppKit
    /// while pointer is locked. Supports both physical mice and MacBook trackpads cleanly without UI click leaks.
    func injectPlatformMouseDelta(dx: Float, dy: Float) {
        inputQueue.async { [runtime] in
            Self.handleMouseDeltaLocked(runtime: runtime, deltaX: dx, deltaY: dy)
        }
    }

    func injectPlatformMouseButton(buttonIndex: Int, pressed: Bool) {
        guard buttonIndex >= 0 && buttonIndex <= 4 else { return }
        let bit: UInt8 = 1 << UInt8(buttonIndex)
        inputQueue.async { [runtime] in
            Self.handleMouseButtonLocked(runtime: runtime, bit: bit, pressed: pressed)
        }
    }

    func injectPlatformMouseScroll(dx: Float, dy: Float) {
        inputQueue.async { [runtime] in
            Self.handleMouseScrollLocked(runtime: runtime, xVal: dx, yVal: dy)
        }
    }

    func clearPlatformMouseState() {
        inputQueue.async { [runtime] in
            let hadButtons = runtime.mouseButtonsMask != 0
            runtime.pendingMouseDX = 0
            runtime.pendingMouseDY = 0
            runtime.mouseSmoothX = 0
            runtime.mouseSmoothY = 0
            runtime.nativeMouseFracX = 0
            runtime.nativeMouseFracY = 0
            runtime.mouseVelX = 0
            runtime.mouseVelY = 0
            runtime.mouseButtonsMask = 0
            runtime.scrollPulseKind = 0
            runtime.scrollPulseUntil = 0
            if runtime.isStreamingActive {
                if runtime.kmMode == .nativeKM && hadButtons {
                    runtime.onMouseEvent?(0, 0, 0, 0, 0, 0)
                } else if runtime.kmMode == .gamepadEmulation {
                    Self.sendSlotLocked(runtime: runtime, slot: 0, force: false)
                }
            }
        }
    }

    func injectPlatformKey(_ keyCode: GCKeyCode, pressed: Bool) {
        inputQueue.async { [runtime] in
            guard runtime.isStreamingActive, runtime.kmMode != .off else { return }
            if pressed {
                runtime.pressedKeys.insert(keyCode)
            } else {
                runtime.pressedKeys.remove(keyCode)
            }
            if runtime.kmMode == .nativeKM {
                if let vk = Self.hidKeyToWindowsVK(keyCode) {
                    runtime.onKeyboardEvent?(vk, pressed)
                }
            } else {
                Self.sendSlotLocked(runtime: runtime, slot: 0, force: false)
            }
        }
    }

    private func bindHardwareKeyboardAndMouse() {
        if let keyboard = GCKeyboard.coalesced {
            keyboard.handlerQueue = inputQueue
            keyboard.keyboardInput?.keyChangedHandler = { [runtime] _, _, keyCode, pressed in
                guard runtime.isStreamingActive, runtime.kmMode != .off else { return }
                if pressed {
                    runtime.pressedKeys.insert(keyCode)
                } else {
                    runtime.pressedKeys.remove(keyCode)
                }
                if runtime.kmMode == .nativeKM {
                    if let vk = Self.hidKeyToWindowsVK(keyCode) {
                        runtime.onKeyboardEvent?(vk, pressed)
                    }
                } else {
                    Self.sendSlotLocked(runtime: runtime, slot: 0, force: false)
                }
            }
        }

        // On macOS, pointer-locked AppKit NSEvent monitoring drives mouse & trackpad cleanly
        // (prevents UI clicks from firing into Xbox, supports Trackpad & side buttons, avoids double-counting).
        #if os(iOS)
        let mice = GCMouse.mice()
        if mice.isEmpty {
            inputQueue.async { [runtime] in
                runtime.mouseButtonsMask = 0
                runtime.pendingMouseDX = 0
                runtime.pendingMouseDY = 0
                runtime.mouseSmoothX = 0
                runtime.mouseSmoothY = 0
                runtime.mouseVelX = 0
                runtime.mouseVelY = 0
            }
        }
        for mouse in mice {
            mouse.handlerQueue = inputQueue
            mouse.mouseInput?.mouseMovedHandler = { [runtime] (_: GCMouseInput, deltaX: Float, deltaY: Float) in
                Self.handleMouseDeltaLocked(runtime: runtime, deltaX: deltaX, deltaY: deltaY)
            }

            mouse.mouseInput?.leftButton.pressedChangedHandler = { [runtime] _, _, pressed in
                Self.handleMouseButtonLocked(runtime: runtime, bit: 1 << 0, pressed: pressed)
            }
            mouse.mouseInput?.rightButton?.pressedChangedHandler = { [runtime] _, _, pressed in
                Self.handleMouseButtonLocked(runtime: runtime, bit: 1 << 1, pressed: pressed)
            }
            mouse.mouseInput?.middleButton?.pressedChangedHandler = { [runtime] _, _, pressed in
                Self.handleMouseButtonLocked(runtime: runtime, bit: 1 << 2, pressed: pressed)
            }
            mouse.mouseInput?.scroll.valueChangedHandler = { [runtime] (_: GCControllerDirectionPad, xVal: Float, yVal: Float) in
                Self.handleMouseScrollLocked(runtime: runtime, xVal: xVal, yVal: yVal)
            }
        }
        #endif
    }

    private nonisolated static func handleMouseDeltaLocked(
        runtime: InputRuntime,
        deltaX: Float,
        deltaY: Float
    ) {
        guard runtime.isStreamingActive, runtime.kmMode != .off else { return }
        if runtime.kmMode == .nativeKM {
            let scale = runtime.mouseSensitivity
            let yDir: Float = runtime.mouseInvertY ? 1.0 : -1.0
            runtime.nativeMouseFracX += deltaX * scale
            runtime.nativeMouseFracY += deltaY * scale * runtime.mouseYScale * yDir
            let ix = Int32(runtime.nativeMouseFracX.rounded(.towardZero))
            let iy = Int32(runtime.nativeMouseFracY.rounded(.towardZero))
            if ix != 0 || iy != 0 {
                runtime.nativeMouseFracX -= Float(ix)
                runtime.nativeMouseFracY -= Float(iy)
                runtime.onMouseEvent?(ix, iy, 0, 0, runtime.mouseButtonsMask & 0x07, 0)
            }
        } else {
            // Accumulate raw hardware deltas between 120Hz ticks (consumed & integrated on every tick)
            runtime.pendingMouseDX += deltaX
            runtime.pendingMouseDY += deltaY
            runtime.lastMouseMoveTime = CACurrentMediaTime()
        }
    }

    private nonisolated static func handleMouseScrollLocked(
        runtime: InputRuntime,
        xVal: Float,
        yVal: Float
    ) {
        guard runtime.isStreamingActive, runtime.kmMode != .off else { return }
        if runtime.kmMode == .nativeKM {
            let wx = Int32((xVal * 120.0).rounded())
            let wy = Int32((yVal * 120.0).rounded())
            if wx != 0 || wy != 0 {
                runtime.onMouseEvent?(0, 0, wx, wy, runtime.mouseButtonsMask & 0x07, 0)
            }
        } else {
            let action = runtime.keyBindings.scrollAction
            guard action != .off, abs(yVal) > 0.05 else { return }
            let up = yVal > 0
            switch action {
            case .off:
                return
            case .dpadUpDown:
                runtime.scrollPulseKind = up ? 1 : 2
            case .dpadLeftRight:
                runtime.scrollPulseKind = up ? 3 : 4
            case .lbRb:
                runtime.scrollPulseKind = up ? 5 : 6
            }
            runtime.scrollPulseUntil = CACurrentMediaTime() + 0.065
            sendSlotLocked(runtime: runtime, slot: 0, force: false)
        }
    }

    private nonisolated static func handleMouseButtonLocked(
        runtime: InputRuntime,
        bit: UInt8,
        pressed: Bool
    ) {
        guard runtime.isStreamingActive, runtime.kmMode != .off else { return }
        if pressed {
            runtime.mouseButtonsMask |= bit
        } else {
            runtime.mouseButtonsMask &= ~bit
        }
        if runtime.kmMode == .nativeKM {
            runtime.onMouseEvent?(0, 0, 0, 0, runtime.mouseButtonsMask & 0x07, 0)
        } else {
            sendSlotLocked(runtime: runtime, slot: 0, force: false)
        }
    }

    // MARK: - Model Identification

    private static func identifyController(_ controller: GCController, index: Int) -> ControllerDeviceInfo {
        let vendor = (controller.vendorName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = controller.productCategory
        let lowerVendor = vendor.lowercased()
        let lowerCat = category.lowercased()

        let modelName: String
        let shortName: String
        let icon: String

        if let xboxPad = controller.extendedGamepad as? GCXboxGamepad {
            icon = "xbox.logo"
            if xboxPad.paddleButton1 != nil || lowerVendor.contains("elite") {
                modelName = "Xbox Elite Series 2"
                shortName = "Xbox Elite 2"
            } else if controller.physicalInputProfile.buttons[GCInputButtonShare] != nil
                        || lowerVendor.contains("series") {
                modelName = "Xbox Series X|S 手柄"
                shortName = "Xbox Series"
            } else {
                modelName = "Xbox One 无线手柄"
                shortName = "Xbox One"
            }
        } else if controller.extendedGamepad is GCDualSenseGamepad {
            icon = "playstation.logo"
            if lowerVendor.contains("edge") {
                modelName = "PS5 DualSense Edge"
                shortName = "DualSense Edge"
            } else {
                modelName = "PS5 DualSense"
                shortName = "DualSense"
            }
        } else if controller.extendedGamepad is GCDualShockGamepad {
            icon = "playstation.logo"
            modelName = "PS4 DualShock 4"
            shortName = "DualShock 4"
        } else if lowerVendor.contains("backbone") || lowerCat.contains("backbone") {
            icon = "gamecontroller.fill"
            modelName = vendor.isEmpty ? "Backbone One" : vendor
            shortName = "Backbone"
        } else if lowerVendor.contains("pro controller") || lowerCat.contains("switch pro") {
            icon = "gamecontroller.fill"
            modelName = "Nintendo Switch Pro"
            shortName = "Switch Pro"
        } else if lowerVendor.contains("joy-con") || lowerCat.contains("joy-con") {
            icon = "gamecontroller.fill"
            modelName = "Nintendo Joy-Con"
            shortName = "Joy-Con"
        } else if lowerVendor.contains("gamesir") || lowerVendor.contains("8bitdo")
                    || lowerVendor.contains("kishi") || lowerVendor.contains("flydigi")
                    || lowerVendor.contains("gulikit") {
            icon = "gamecontroller.fill"
            modelName = vendor
            shortName = vendor.count > 14 ? String(vendor.prefix(13)) + "…" : vendor
        } else {
            icon = "gamecontroller.fill"
            let fallback = !vendor.isEmpty ? vendor : (!category.isEmpty ? category : "MFi 游戏手柄")
            modelName = fallback
            shortName = fallback.count > 14 ? String(fallback.prefix(13)) + "…" : fallback
        }

        let localities = controller.haptics?.supportedLocalities ?? []
        let hasHandle = localities.contains(.leftHandle)
            || localities.contains(.rightHandle)
            || localities.contains(.handles)
            || localities.contains(.default)
        let hasTrigger = localities.contains(.leftTrigger) || localities.contains(.rightTrigger)
        let hasGyro = controller.motion != nil

        var batteryPct: Int?
        var charging = false
        if let bat = controller.battery, bat.batteryState != .unknown, bat.batteryLevel >= 0 {
            batteryPct = Int((bat.batteryLevel * 100.0).rounded())
            charging = (bat.batteryState == .charging)
        }

        return ControllerDeviceInfo(
            id: "\(index)-\(vendor)-\(category)",
            playerIndex: index,
            modelName: modelName,
            shortModelName: shortName,
            vendorRawName: vendor,
            categoryIcon: icon,
            supportsHandleRumble: hasHandle,
            supportsTriggerRumble: hasTrigger,
            supportsGyro: hasGyro,
            batteryPercent: batteryPct,
            isCharging: charging
        )
    }

    // MARK: - Zero-Hop 120Hz Real-Time Input Sampling (`inputQueue` only)

    private nonisolated static func startHighFrequencyPollingLocked(
        runtime: InputRuntime,
        queue: DispatchQueue
    ) {
        runtime.pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .microseconds(8_333), leeway: .microseconds(500))
        timer.setEventHandler {
            if runtime.kmMode == .gamepadEmulation {
                let now = CACurrentMediaTime()
                let dx = runtime.pendingMouseDX
                let dy = runtime.pendingMouseDY
                runtime.pendingMouseDX = 0
                runtime.pendingMouseDY = 0

                let baseGain: Float = 0.068 * runtime.mouseSensitivity
                let sampleX = dx * baseGain
                let sampleY = dy * baseGain * runtime.mouseYScale

                if abs(dx) > 0.0001 || abs(dy) > 0.0001 {
                    runtime.mouseSmoothX = runtime.mouseSmoothX * 0.28 + sampleX * 0.72
                    runtime.mouseSmoothY = runtime.mouseSmoothY * 0.28 + sampleY * 0.72
                } else {
                    let idle = now - runtime.lastMouseMoveTime
                    // Keep brief continuity across 60Hz–90Hz USB/Bluetooth/Trackpad intervals,
                    // then snap cleanly to zero as soon as hand stops moving.
                    let decay: Float = idle < 0.018 ? 0.80 : 0.42
                    runtime.mouseSmoothX *= decay
                    runtime.mouseSmoothY *= decay
                    if abs(runtime.mouseSmoothX) < 0.012 { runtime.mouseSmoothX = 0 }
                    if abs(runtime.mouseSmoothY) < 0.012 { runtime.mouseSmoothY = 0 }
                }

                // Apply circular response curve + in-game right-stick anti-deadzone lift
                // so micro-aiming immediately clears console games' built-in 15-22% deadzone.
                let rawMag = hypot(runtime.mouseSmoothX, runtime.mouseSmoothY)
                if rawMag > 0.012 {
                    let clamped = min(rawMag, 1.0)
                    let curved = pow(clamped, 0.76)
                    let antiDZ = max(0.0, min(0.38, runtime.mouseAntiDeadzone))
                    let outMag = min(1.0, antiDZ + (1.0 - antiDZ) * curved)
                    let scale = outMag / rawMag
                    runtime.mouseVelX = runtime.mouseSmoothX * scale
                    runtime.mouseVelY = runtime.mouseSmoothY * scale * (runtime.mouseInvertY ? -1.0 : 1.0)
                } else {
                    runtime.mouseVelX = 0
                    runtime.mouseVelY = 0
                }

                if runtime.scrollPulseKind != 0 && now >= runtime.scrollPulseUntil {
                    runtime.scrollPulseKind = 0
                }

                // Smooth right-stick ramp when using arrow keys in Pure Keyboard mode
                if runtime.keyBindings.arrowsAsRightStick {
                    let keys = runtime.pressedKeys
                    var tx: Float = 0
                    var ty: Float = 0
                    if keys.contains(.leftArrow) { tx -= 1 }
                    if keys.contains(.rightArrow) { tx += 1 }
                    if keys.contains(.upArrow) { ty += 1 }
                    if keys.contains(.downArrow) { ty -= 1 }
                    if tx != 0 && ty != 0 {
                        tx *= 0.70710678
                        ty *= 0.70710678
                    }
                    let speed: Float = (runtime.keyBindings.altSlowWalk && keys.contains(.leftAlt)) ? 0.48 : 0.88
                    runtime.arrowStickX = runtime.arrowStickX * 0.45 + (tx * speed) * 0.55
                    runtime.arrowStickY = runtime.arrowStickY * 0.45 + (ty * speed) * 0.55
                    if abs(runtime.arrowStickX) < 0.01 { runtime.arrowStickX = 0 }
                    if abs(runtime.arrowStickY) < 0.01 { runtime.arrowStickY = 0 }
                } else {
                    runtime.arrowStickX = 0
                    runtime.arrowStickY = 0
                }
            }
            sendAllSlotsLocked(runtime: runtime, force: false)
        }
        timer.resume()
        runtime.pollTimer = timer
    }

    private nonisolated static func handleGamepadChangeLocked(runtime: InputRuntime) {
        if runtime.isStreamingActive {
            sendAllSlotsLocked(runtime: runtime, force: false)
        } else {
            let now = CACurrentMediaTime()
            if let primary = runtime.controllers.first, let pad = primary.extendedGamepad {
                // Couch Mode non-streaming UI navigation: buttons are rising-edge triggered,
                // D-pad & left stick repeat smoothly every 190ms.
                var btnMask: UInt8 = 0
                let swapAB = runtime.nintendoLayout == .alwaysSwap
                    || (runtime.nintendoLayout == .auto && runtime.isNintendoSlot[0])
                let confirmPressed = swapAB ? pad.buttonB.isPressed : pad.buttonA.isPressed
                let backPressed = swapAB ? pad.buttonA.isPressed : pad.buttonB.isPressed
                if confirmPressed { btnMask |= 1 << 0 }
                if backPressed { btnMask |= 1 << 1 }
                if pad.leftShoulder.isPressed { btnMask |= 1 << 2 }
                if pad.rightShoulder.isPressed { btnMask |= 1 << 3 }

                let rising = btnMask & ~runtime.lastMenuButtonsMask
                runtime.lastMenuButtonsMask = btnMask

                if (rising & (1 << 0)) != 0 { runtime.onMenuAction?(.confirm) }
                if (rising & (1 << 1)) != 0 { runtime.onMenuAction?(.back) }
                if (rising & (1 << 2)) != 0 { runtime.onMenuAction?(.prevTab) }
                if (rising & (1 << 3)) != 0 { runtime.onMenuAction?(.nextTab) }

                let lx = pad.leftThumbstick.xAxis.value
                let ly = pad.leftThumbstick.yAxis.value
                var dirAction: GamepadMenuAction?
                if pad.dpad.up.isPressed || ly > 0.65 {
                    dirAction = .up
                } else if pad.dpad.down.isPressed || ly < -0.65 {
                    dirAction = .down
                } else if pad.dpad.left.isPressed || lx < -0.65 {
                    dirAction = .left
                } else if pad.dpad.right.isPressed || lx > 0.65 {
                    dirAction = .right
                }
                if let dirAction, (now - runtime.lastMenuDirTime) >= 0.19 {
                    runtime.lastMenuDirTime = now
                    runtime.onMenuAction?(dirAction)
                } else if dirAction == nil {
                    runtime.lastMenuDirTime = 0
                }
            }
            if now - runtime.lastTelemetryPush >= 0.05 {
                runtime.lastTelemetryPush = now
                runtime.onNonStreamingUpdate?()
            }
        }
    }

    private nonisolated static func sendAllSlotsLocked(runtime: InputRuntime, force: Bool) {
        let slotCount = max(runtime.controllers.count, 1)
        for slot in 0..<min(slotCount, 4) {
            sendSlotLocked(runtime: runtime, slot: slot, force: force)
        }
    }

    private nonisolated static func sendSlotLocked(runtime: InputRuntime, slot: Int, force: Bool) {
        let frame = buildFrameLocked(runtime: runtime, slot: slot)
        if slot == 0 {
            checkOverlayComboLocked(runtime: runtime, frame: frame)
        }
        if force || !framesEqual(frame, runtime.lastFrames[slot]) {
            runtime.lastFrames[slot] = frame
            if runtime.isStreamingActive {
                runtime.onInputFrame?(frame)
            }
        }
    }

    private nonisolated static func checkOverlayComboLocked(
        runtime: InputRuntime,
        frame: XboxPadInputFrame
    ) {
        guard runtime.isStreamingActive, runtime.menuComboEnabled else {
            runtime.comboStartTime = 0
            runtime.comboFiredForCurrentHold = false
            return
        }
        if frame.view > 0 && frame.menu > 0 {
            let now = CACurrentMediaTime()
            if runtime.comboStartTime == 0 {
                runtime.comboStartTime = now
                runtime.comboFiredForCurrentHold = false
            } else if !runtime.comboFiredForCurrentHold,
                      (now - runtime.comboStartTime) >= 0.45 {
                runtime.comboFiredForCurrentHold = true
                runtime.onComboTriggered?()
            }
        } else {
            runtime.comboStartTime = 0
            runtime.comboFiredForCurrentHold = false
        }
    }

    private nonisolated static func buildFrameLocked(runtime: InputRuntime, slot: Int) -> XboxPadInputFrame {
        var frame = XboxPadInputFrame()
        frame.gamepad_index = UInt8(slot)

        if slot < runtime.controllers.count {
            let controller = runtime.controllers[slot]
            if let pad = controller.extendedGamepad {
                let exp = runtime.responseExponent
                let (lx, ly) = applyCircularDeadzoneAndCurve(
                    x: pad.leftThumbstick.xAxis.value,
                    y: pad.leftThumbstick.yAxis.value,
                    deadzone: runtime.leftDeadzone,
                    exponent: exp
                )
                let (rx, ry) = applyCircularDeadzoneAndCurve(
                    x: pad.rightThumbstick.xAxis.value,
                    y: pad.rightThumbstick.yAxis.value,
                    deadzone: runtime.rightDeadzone,
                    exponent: exp
                )

                let shouldSwapNintendo = runtime.nintendoLayout == .alwaysSwap
                    || (runtime.nintendoLayout == .auto && slot < runtime.isNintendoSlot.count && runtime.isNintendoSlot[slot])
                if shouldSwapNintendo {
                    frame.a = pad.buttonB.isPressed ? 1 : 0
                    frame.b = pad.buttonA.isPressed ? 1 : 0
                    frame.x = pad.buttonY.isPressed ? 1 : 0
                    frame.y = pad.buttonX.isPressed ? 1 : 0
                } else {
                    frame.a = pad.buttonA.isPressed ? 1 : 0
                    frame.b = pad.buttonB.isPressed ? 1 : 0
                    frame.x = pad.buttonX.isPressed ? 1 : 0
                    frame.y = pad.buttonY.isPressed ? 1 : 0
                }
                frame.dpad_up = pad.dpad.up.isPressed ? 1 : 0
                frame.dpad_down = pad.dpad.down.isPressed ? 1 : 0
                frame.dpad_left = pad.dpad.left.isPressed ? 1 : 0
                frame.dpad_right = pad.dpad.right.isPressed ? 1 : 0
                frame.left_shoulder = pad.leftShoulder.isPressed ? 1 : 0
                frame.right_shoulder = pad.rightShoulder.isPressed ? 1 : 0
                frame.left_thumb = (pad.leftThumbstickButton?.isPressed ?? false) ? 1 : 0
                frame.right_thumb = (pad.rightThumbstickButton?.isPressed ?? false) ? 1 : 0
                frame.menu = pad.buttonMenu.isPressed ? 1 : 0
                frame.view = (pad.buttonOptions?.isPressed ?? false) ? 1 : 0
                let liveHomePressed: Bool = {
                    if #available(iOS 17.0, *) {
                        return controller.input.buttons[.home]?.pressedInput.isPressed ?? false
                    }
                    return false
                }()
                let homePressed = (pad.buttonHome?.isPressed ?? false)
                    || (controller.physicalInputProfile.buttons[GCInputButtonHome]?.isPressed ?? false)
                    || liveHomePressed
                let sharePressed = runtime.mapShareToNexus
                    && (controller.physicalInputProfile.buttons[GCInputButtonShare]?.isPressed ?? false)
                frame.nexus = (homePressed || sharePressed) ? 1 : 0

                let bMap = runtime.buttonMap
                let outLX = bMap.swapSticks ? rx : lx
                let outLYRaw = bMap.swapSticks ? ry : ly
                let outRX = bMap.swapSticks ? lx : rx
                let outRYRaw = bMap.swapSticks ? ly : ry
                frame.left_thumb_x = outLX
                frame.left_thumb_y = bMap.invertLeftY ? outLYRaw : -outLYRaw
                frame.right_thumb_x = outRX
                frame.right_thumb_y = bMap.invertRightY ? outRYRaw : -outRYRaw

                let rawLT = applyTriggerDeadzone(pad.leftTrigger.value, deadzone: runtime.triggerDeadzone)
                let rawRT = applyTriggerDeadzone(pad.rightTrigger.value, deadzone: runtime.triggerDeadzone)
                if bMap.swapTriggersAndBumpers {
                    let origLB = frame.left_shoulder
                    let origRB = frame.right_shoulder
                    frame.left_shoulder = rawLT > 0.25 ? 1 : 0
                    frame.right_shoulder = rawRT > 0.25 ? 1 : 0
                    frame.left_trigger = origLB > 0 ? 1.0 : 0.0
                    frame.right_trigger = origRB > 0 ? 1.0 : 0.0
                } else {
                    frame.left_trigger = rawLT
                    frame.right_trigger = rawRT
                }

                // Xbox Elite Series 2 back paddles (P1–P4) custom mapping
                if let xboxPad = pad as? GCXboxGamepad {
                    if xboxPad.paddleButton1?.isPressed == true { applyPaddleAction(bMap.paddle1, to: &frame) }
                    if xboxPad.paddleButton2?.isPressed == true { applyPaddleAction(bMap.paddle2, to: &frame) }
                    if xboxPad.paddleButton3?.isPressed == true { applyPaddleAction(bMap.paddle3, to: &frame) }
                    if xboxPad.paddleButton4?.isPressed == true { applyPaddleAction(bMap.paddle4, to: &frame) }
                }
            }
        }

        // Virtual touch overlay, Keyboard+Mouse emulation, and Gyro aiming apply to P1 (slot 0)
        guard slot == 0 else { return frame }

        if runtime.hasVirtualInput {
            let v = runtime.virtualOverrides
            frame.nexus = max(frame.nexus, v.nexus)
            frame.menu = max(frame.menu, v.menu)
            frame.view = max(frame.view, v.view)
            frame.a = max(frame.a, v.a)
            frame.b = max(frame.b, v.b)
            frame.x = max(frame.x, v.x)
            frame.y = max(frame.y, v.y)
            frame.dpad_up = max(frame.dpad_up, v.dpad_up)
            frame.dpad_down = max(frame.dpad_down, v.dpad_down)
            frame.dpad_left = max(frame.dpad_left, v.dpad_left)
            frame.dpad_right = max(frame.dpad_right, v.dpad_right)
            frame.left_shoulder = max(frame.left_shoulder, v.left_shoulder)
            frame.right_shoulder = max(frame.right_shoulder, v.right_shoulder)
            frame.left_thumb = max(frame.left_thumb, v.left_thumb)
            frame.right_thumb = max(frame.right_thumb, v.right_thumb)

            if abs(runtime.virtualLeftX) > 0.001 || abs(runtime.virtualLeftY) > 0.001 {
                frame.left_thumb_x = max(-1.0, min(1.0, frame.left_thumb_x + runtime.virtualLeftX))
                frame.left_thumb_y = max(-1.0, min(1.0, frame.left_thumb_y - runtime.virtualLeftY))
            }
            if abs(runtime.virtualRightX) > 0.001 || abs(runtime.virtualRightY) > 0.001 {
                frame.right_thumb_x = max(-1.0, min(1.0, frame.right_thumb_x + runtime.virtualRightX))
                frame.right_thumb_y = max(-1.0, min(1.0, frame.right_thumb_y - runtime.virtualRightY))
            }
            frame.left_trigger = max(frame.left_trigger, runtime.virtualLeftTrigger)
            frame.right_trigger = max(frame.right_trigger, runtime.virtualRightTrigger)
        }

        // Keyboard & Mouse -> Xbox Gamepad Emulation (works on 100% of Xbox console & cloud games!)
        if runtime.kmMode == .gamepadEmulation {
            let keys = runtime.pressedKeys
            let hasScroll = runtime.scrollPulseKind != 0
            let hasArrowStick = abs(runtime.arrowStickX) > 0.001 || abs(runtime.arrowStickY) > 0.001
            if !keys.isEmpty || runtime.mouseButtonsMask != 0 || hasScroll || hasArrowStick
                || abs(runtime.mouseVelX) > 0.001 || abs(runtime.mouseVelY) > 0.001 {
                let kb = runtime.keyBindings
                var kx: Float = 0
                var ky: Float = 0
                if keys.contains(.keyA) { kx -= 1 }
                if keys.contains(.keyD) { kx += 1 }
                if kb.wasdDriveTriggers {
                    if keys.contains(.keyW) { frame.right_trigger = 1.0 }
                    if keys.contains(.keyS) { frame.left_trigger = 1.0 }
                } else {
                    if keys.contains(.keyW) { ky += 1 }
                    if keys.contains(.keyS) { ky -= 1 }
                }
                if kx != 0 && ky != 0 {
                    let inv: Float = 0.70710678
                    kx *= inv
                    ky *= inv
                }
                if kb.altSlowWalk && keys.contains(.leftAlt) {
                    kx *= 0.45
                    ky *= 0.45
                }
                if kx != 0 || ky != 0 {
                    frame.left_thumb_x = max(-1.0, min(1.0, frame.left_thumb_x + kx))
                    frame.left_thumb_y = max(-1.0, min(1.0, frame.left_thumb_y - ky))
                }
                let rxCombined = runtime.mouseVelX + runtime.arrowStickX
                let ryCombined = runtime.mouseVelY + runtime.arrowStickY
                if abs(rxCombined) > 0.001 || abs(ryCombined) > 0.001 {
                    frame.right_thumb_x = max(-1.0, min(1.0, frame.right_thumb_x + rxCombined))
                    frame.right_thumb_y = max(-1.0, min(1.0, frame.right_thumb_y - ryCombined))
                }

                // Customizable mouse button mappings (LMB, RMB, MMB, Side1, Side2)
                if (runtime.mouseButtonsMask & (1 << 0)) != 0 { applyMouseAction(kb.leftClick, to: &frame) }
                if (runtime.mouseButtonsMask & (1 << 1)) != 0 { applyMouseAction(kb.rightClick, to: &frame) }
                if (runtime.mouseButtonsMask & (1 << 2)) != 0 { applyMouseAction(kb.middleClick, to: &frame) }
                if (runtime.mouseButtonsMask & (1 << 3)) != 0 { applyMouseAction(kb.sideButton1, to: &frame) }
                if (runtime.mouseButtonsMask & (1 << 4)) != 0 { applyMouseAction(kb.sideButton2, to: &frame) }

                // Scroll wheel pulse
                switch runtime.scrollPulseKind {
                case 1: frame.dpad_up = 1
                case 2: frame.dpad_down = 1
                case 3: frame.dpad_left = 1
                case 4: frame.dpad_right = 1
                case 5: frame.left_shoulder = 1
                case 6: frame.right_shoulder = 1
                default: break
                }

                if Self.isKeyPressed(kb.aKey, in: keys) || keys.contains(.returnOrEnter) { frame.a = 1 }
                if Self.isKeyPressed(kb.bKey, in: keys) || keys.contains(.deleteOrBackspace) { frame.b = 1 }
                if Self.isKeyPressed(kb.xKey, in: keys) { frame.x = 1 }
                if Self.isKeyPressed(kb.yKey, in: keys) { frame.y = 1 }
                if Self.isKeyPressed(kb.lbKey, in: keys) { frame.left_shoulder = 1 }
                if Self.isKeyPressed(kb.rbKey, in: keys) { frame.right_shoulder = 1 }
                if Self.isKeyPressed(kb.ltKey, in: keys) { frame.left_trigger = 1.0 }
                if Self.isKeyPressed(kb.rtKey, in: keys) { frame.right_trigger = 1.0 }
                if Self.isKeyPressed(kb.l3Key, in: keys) { frame.left_thumb = 1 }
                if Self.isKeyPressed(kb.r3Key, in: keys) { frame.right_thumb = 1 }

                // D-Pad: arrow keys (unless arrows drive right stick) + convenient 1/2/3/4 beside WASD
                if !kb.arrowsAsRightStick {
                    if keys.contains(.upArrow) { frame.dpad_up = 1 }
                    if keys.contains(.downArrow) { frame.dpad_down = 1 }
                    if keys.contains(.leftArrow) { frame.dpad_left = 1 }
                    if keys.contains(.rightArrow) { frame.dpad_right = 1 }
                }
                if kb.numberKeysAsDpad {
                    if keys.contains(.one) { frame.dpad_up = 1 }
                    if keys.contains(.two) { frame.dpad_down = 1 }
                    if keys.contains(.three) { frame.dpad_left = 1 }
                    if keys.contains(.four) { frame.dpad_right = 1 }
                }

                if Self.isKeyPressed(kb.viewKey, in: keys) { frame.view = 1 }
                if Self.isKeyPressed(kb.menuKey, in: keys) { frame.menu = 1 }
                if Self.isKeyPressed(kb.nexusKey, in: keys) { frame.nexus = 1 }
            }
        }

        // Gyro aiming injection onto right stick
        let gyroActive: Bool = {
            switch runtime.gyroMode {
            case .off: return false
            case .alwaysOn: return true
            case .onLeftTrigger: return frame.left_trigger > 0.12
            }
        }()
        if gyroActive {
            let rawX: Float
            let rawY: Float
            if let primary = runtime.controllers.first, let motion = primary.motion, motion.hasRotationRate {
                let rr = motion.rotationRate
                rawX = Float(-rr.y)
                rawY = Float(rr.x)
            } else {
                rawX = runtime.deviceGyroX
                rawY = runtime.deviceGyroY
            }
            let gain = 0.22 * runtime.gyroSensitivity
            let gx = abs(rawX) > 0.035 ? rawX * gain : 0
            let gy = abs(rawY) > 0.035 ? rawY * gain * (runtime.gyroInvertY ? -1.0 : 1.0) : 0
            frame.right_thumb_x = max(-1.0, min(1.0, frame.right_thumb_x + gx))
            frame.right_thumb_y = max(-1.0, min(1.0, frame.right_thumb_y - gy))
        }

        return frame
    }

    private nonisolated static func applyPaddleAction(_ action: PaddleAction, to frame: inout XboxPadInputFrame) {
        switch action {
        case .none: break
        case .a: frame.a = 1
        case .b: frame.b = 1
        case .x: frame.x = 1
        case .y: frame.y = 1
        case .lb: frame.left_shoulder = 1
        case .rb: frame.right_shoulder = 1
        case .l3: frame.left_thumb = 1
        case .r3: frame.right_thumb = 1
        case .view: frame.view = 1
        case .menu: frame.menu = 1
        }
    }

    private nonisolated static func applyMouseAction(_ action: MouseButtonAction, to frame: inout XboxPadInputFrame) {
        switch action {
        case .none: break
        case .rt: frame.right_trigger = 1.0
        case .lt: frame.left_trigger = 1.0
        case .rb: frame.right_shoulder = 1
        case .lb: frame.left_shoulder = 1
        case .a: frame.a = 1
        case .b: frame.b = 1
        case .x: frame.x = 1
        case .y: frame.y = 1
        case .l3: frame.left_thumb = 1
        case .r3: frame.right_thumb = 1
        case .view: frame.view = 1
        case .menu: frame.menu = 1
        }
    }

    private nonisolated static func isKeyPressed(_ name: String, in keys: Set<GCKeyCode>) -> Bool {
        guard !name.isEmpty, let code = gcKeyCode(forName: name) else { return false }
        return keys.contains(code)
    }

    private nonisolated static func gcKeyCode(forName name: String) -> GCKeyCode? {
        switch name {
        case "Space": return .spacebar
        case "Enter": return .returnOrEnter
        case "Tab": return .tab
        case "Esc": return .escape
        case "LShift": return .leftShift
        case "LCtrl": return .leftControl
        case "LAlt": return .leftAlt
        case "Backspace": return .deleteOrBackspace
        case "Q": return .keyQ
        case "E": return .keyE
        case "R": return .keyR
        case "T": return .keyT
        case "F": return .keyF
        case "G": return .keyG
        case "Z": return .keyZ
        case "X": return .keyX
        case "C": return .keyC
        case "V": return .keyV
        case "B": return .keyB
        case "M": return .keyM
        case "P": return .keyP
        case "U": return .keyU
        case "I": return .keyI
        case "O": return .keyO
        case "J": return .keyJ
        case "K": return .keyK
        case "L": return .keyL
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "F12": return .F12
        default: return nil
        }
    }

    private nonisolated static func applyCircularDeadzoneAndCurve(
        x: Float,
        y: Float,
        deadzone: Float,
        exponent: Float
    ) -> (Float, Float) {
        let mag = hypot(x, y)
        guard mag > deadzone, deadzone < 0.95 else { return (0, 0) }
        let rescaled = min((mag - deadzone) / (1.0 - deadzone), 1.0)
        let curved = abs(exponent - 1.0) < 0.01 ? rescaled : pow(rescaled, exponent)
        let scale = curved / mag
        return (x * scale, y * scale)
    }

    private nonisolated static func applyTriggerDeadzone(_ value: Float, deadzone: Float) -> Float {
        guard value > deadzone, deadzone < 0.95 else { return 0 }
        return min((value - deadzone) / (1.0 - deadzone), 1.0)
    }

    private func refreshTelemetrySnapshot() {
        let infos = connectedControllers.enumerated().map { idx, c in
            Self.identifyController(c, index: idx)
        }
        let kb = GCKeyboard.coalesced
        let ms = GCMouse.current ?? GCMouse.mice().first
        let kbName = kb?.vendorName ?? (kb != nil ? "外接键盘" : "")
        let msName = ms?.vendorName ?? (ms != nil ? "外接鼠标" : "")

        guard !connectedControllers.isEmpty else {
            telemetry = GamepadTelemetry(
                connected: false,
                name: "未连接手柄",
                modelName: "未连接手柄",
                supportsHandleRumble: false,
                supportsTriggerRumble: false,
                controllers: [],
                selectedSlotIndex: 0,
                keyboardConnected: kb != nil,
                mouseConnected: ms != nil,
                keyboardName: kbName,
                mouseName: msName
            )
            return
        }

        let safeIdx = min(selectedSlotIndex, connectedControllers.count - 1)
        let controller = connectedControllers[safeIdx]
        let info = infos[safeIdx]
        guard let pad = controller.extendedGamepad else { return }

        var buttons: [String] = []
        if pad.buttonA.isPressed { buttons.append("A") }
        if pad.buttonB.isPressed { buttons.append("B") }
        if pad.buttonX.isPressed { buttons.append("X") }
        if pad.buttonY.isPressed { buttons.append("Y") }
        if pad.leftShoulder.isPressed { buttons.append("LB") }
        if pad.rightShoulder.isPressed { buttons.append("RB") }
        if pad.leftThumbstickButton?.isPressed == true { buttons.append("LS") }
        if pad.rightThumbstickButton?.isPressed == true { buttons.append("RS") }
        if pad.buttonMenu.isPressed { buttons.append("Menu") }
        if pad.buttonOptions?.isPressed == true { buttons.append("View") }
        if pad.buttonHome?.isPressed == true { buttons.append("Xbox") }
        if pad.dpad.up.isPressed { buttons.append("↑") }
        if pad.dpad.down.isPressed { buttons.append("↓") }
        if pad.dpad.left.isPressed { buttons.append("←") }
        if pad.dpad.right.isPressed { buttons.append("→") }

        telemetry = GamepadTelemetry(
            connected: true,
            name: info.modelName,
            modelName: info.modelName,
            supportsHandleRumble: info.supportsHandleRumble,
            supportsTriggerRumble: info.supportsTriggerRumble,
            controllers: infos,
            selectedSlotIndex: safeIdx,
            keyboardConnected: kb != nil,
            mouseConnected: ms != nil,
            keyboardName: kbName,
            mouseName: msName,
            activeButtons: buttons,
            leftStickX: pad.leftThumbstick.xAxis.value,
            leftStickY: pad.leftThumbstick.yAxis.value,
            rightStickX: pad.rightThumbstick.xAxis.value,
            rightStickY: pad.rightThumbstick.yAxis.value,
            leftTrigger: pad.leftTrigger.value,
            rightTrigger: pad.rightTrigger.value
        )
    }

    /// Maps Apple USB HID `GCKeyCode` to Windows Virtual-Key (`VK_*`) for Xbox native keyboard input.
    private nonisolated static func hidKeyToWindowsVK(_ key: GCKeyCode) -> UInt8? {
        switch key {
        case .keyA: return 0x41
        case .keyB: return 0x42
        case .keyC: return 0x43
        case .keyD: return 0x44
        case .keyE: return 0x45
        case .keyF: return 0x46
        case .keyG: return 0x47
        case .keyH: return 0x48
        case .keyI: return 0x49
        case .keyJ: return 0x4A
        case .keyK: return 0x4B
        case .keyL: return 0x4C
        case .keyM: return 0x4D
        case .keyN: return 0x4E
        case .keyO: return 0x4F
        case .keyP: return 0x50
        case .keyQ: return 0x51
        case .keyR: return 0x52
        case .keyS: return 0x53
        case .keyT: return 0x54
        case .keyU: return 0x55
        case .keyV: return 0x56
        case .keyW: return 0x57
        case .keyX: return 0x58
        case .keyY: return 0x59
        case .keyZ: return 0x5A
        case .zero: return 0x30
        case .one: return 0x31
        case .two: return 0x32
        case .three: return 0x33
        case .four: return 0x34
        case .five: return 0x35
        case .six: return 0x36
        case .seven: return 0x37
        case .eight: return 0x38
        case .nine: return 0x39
        case .returnOrEnter: return 0x0D
        case .escape: return 0x1B
        case .deleteOrBackspace: return 0x08
        case .tab: return 0x09
        case .spacebar: return 0x20
        case .leftShift, .rightShift: return 0x10
        case .leftControl, .rightControl: return 0x11
        case .leftAlt, .rightAlt: return 0x12
        case .upArrow: return 0x26
        case .downArrow: return 0x28
        case .leftArrow: return 0x25
        case .rightArrow: return 0x27
        case .F1: return 0x70
        case .F2: return 0x71
        case .F3: return 0x72
        case .F4: return 0x73
        case .F5: return 0x74
        case .F6: return 0x75
        case .F7: return 0x76
        case .F8: return 0x77
        case .F9: return 0x78
        case .F10: return 0x79
        case .F11: return 0x7A
        case .F12: return 0x7B
        default: return nil
        }
    }

    private nonisolated static func framesEqual(_ a: XboxPadInputFrame, _ b: XboxPadInputFrame) -> Bool {
        a.gamepad_index == b.gamepad_index
            && a.nexus == b.nexus
            && a.menu == b.menu
            && a.view == b.view
            && a.a == b.a
            && a.b == b.b
            && a.x == b.x
            && a.y == b.y
            && a.dpad_up == b.dpad_up
            && a.dpad_down == b.dpad_down
            && a.dpad_left == b.dpad_left
            && a.dpad_right == b.dpad_right
            && a.left_shoulder == b.left_shoulder
            && a.right_shoulder == b.right_shoulder
            && a.left_thumb == b.left_thumb
            && a.right_thumb == b.right_thumb
            && abs(a.left_thumb_x - b.left_thumb_x) < 0.002
            && abs(a.left_thumb_y - b.left_thumb_y) < 0.002
            && abs(a.right_thumb_x - b.right_thumb_x) < 0.002
            && abs(a.right_thumb_y - b.right_thumb_y) < 0.002
            && abs(a.left_trigger - b.left_trigger) < 0.004
            && abs(a.right_trigger - b.right_trigger) < 0.004
    }
}
