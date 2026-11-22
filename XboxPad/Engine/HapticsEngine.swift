import CoreHaptics
import Foundation
import GameController
import os
import QuartzCore

/// 4-channel native CoreHaptics rumble engine for iPadOS game controllers:
/// - Left Handle (strong low-frequency motor)
/// - Right Handle (weak high-frequency motor)
/// - Left Trigger (Xbox impulse trigger)
/// - Right Trigger (Xbox impulse trigger)
///
/// NOTE: On iPadOS `gamecontrollerd`, `makeAdvancedPlayer` is unsupported and invalidates
/// the XPC client (NSCocoaErrorDomain Code=4097). We therefore use a long-lived simple
/// `CHHapticPatternPlayer` (30s continuous event — CoreHaptics' hard max per event) per
/// actuator and modulate intensity dynamically via `sendParameters(.hapticIntensityControl)`
/// (including 0.0 when idle), recycling only after 25s — minimal XPC churn, zero motor
/// stop/restart braking, 100% compatible with `gamecontrollerd`.
final class HapticsEngine: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "haptics")

    enum MotorChannel: String, CaseIterable, Identifiable {
        case leftHandle = "左握把 (强震)"
        case rightHandle = "右握把 (弱震)"
        case leftTrigger = "左扳机 (LT)"
        case rightTrigger = "右扳机 (RT)"

        var id: String { rawValue }

        var locality: GCHapticsLocality {
            switch self {
            case .leftHandle: return .leftHandle
            case .rightHandle: return .rightHandle
            case .leftTrigger: return .leftTrigger
            case .rightTrigger: return .rightTrigger
            }
        }
    }

    private final class ChannelState {
        let locality: GCHapticsLocality
        let sharpness: Float
        let engine: CHHapticEngine
        var player: CHHapticPatternPlayer?
        var playerStartedAt: CFTimeInterval = 0
        var isEngineStarted = false
        var isPlayerRunning = false
        var currentIntensity: Float = -1
        var stopWorkItem: DispatchWorkItem?

        init(locality: GCHapticsLocality, sharpness: Float, engine: CHHapticEngine) {
            self.locality = locality
            self.sharpness = sharpness
            self.engine = engine
        }
    }

    private let queue = DispatchQueue(label: "com.elliot.xboxpad.haptics", qos: .userInteractive)
    private weak var boundController: GCController?
    private var channels: [GCHapticsLocality: ChannelState] = [:]
    private var supportedLocalities: Set<GCHapticsLocality> = []
    private var pendingSequenceWorkItem: DispatchWorkItem?
    private var auxSlotEngines: [Int: HapticsEngine] = [:]
    private let isChildSlotEngine: Bool
    private var isPhoneTapticFallback = false
    private var lastPhonePunchTime: CFTimeInterval = 0
    private var lastPhoneEnergy: Float = 0

    var settings = AppSettings()

    private(set) var supportsHandleRumble: Bool = false
    private(set) var supportsTriggerRumble: Bool = false

    init(isChildSlotEngine: Bool = false) {
        self.isChildSlotEngine = isChildSlotEngine
    }

    func bind(controller: GCController?) {
        queue.async { [weak self] in
            self?.bindLocked(controller: controller)
        }
    }

    /// Bind up to 4 simultaneous hardware controllers (P1..P4) for independent local co-op rumble routing.
    func bindControllers(_ controllers: [GCController], primarySlot: Int = 0) {
        let p1 = controllers.first
        bind(controller: p1)
        guard !isChildSlotEngine else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for slot in 1..<4 {
                if slot < controllers.count {
                    let sub = self.auxSlotEngines[slot] ?? {
                        let created = HapticsEngine(isChildSlotEngine: true)
                        created.updateSettings(self.settings)
                        self.auxSlotEngines[slot] = created
                        return created
                    }()
                    sub.bind(controller: controllers[slot])
                } else if let existing = self.auxSlotEngines.removeValue(forKey: slot) {
                    existing.bind(controller: nil)
                }
            }
        }
    }

    /// Re-verify CoreHaptics engines after AVAudioSession activation/interruption.
    func prepareForStream() {
        queue.async { [weak self] in
            guard let self else { return }
            for sub in self.auxSlotEngines.values {
                sub.prepareForStream()
            }
            if self.channels.isEmpty, let controller = self.boundController {
                self.bindLocked(controller: controller)
                return
            }
            var visited = Set<ObjectIdentifier>()
            for state in self.channels.values {
                guard visited.insert(ObjectIdentifier(state)).inserted else { continue }
                if !state.isEngineStarted {
                    try? state.engine.start()
                    state.isEngineStarted = true
                }
            }
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = newSettings
            for sub in self.auxSlotEngines.values {
                sub.updateSettings(newSettings)
            }
            if !newSettings.rumbleEnabled {
                self.silenceAllLocked(stopPlayers: true)
            }
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for sub in self.auxSlotEngines.values {
                sub.stopAll()
            }
            self.silenceAllLocked(stopPlayers: true)
        }
    }

    /// Trigger a short subtle confirmation pulse (e.g. menu combo activated).
    func playSubtleConfirmPulse() {
        queue.async { [weak self] in
            guard let self, self.settings.rumbleEnabled else { return }
            self.driveChannel(locality: .rightHandle, intensity: 0.45, durationSec: 0.09)
        }
    }

    /// Manual motor test for the Settings screen so user can verify each motor on the selected player slot.
    func testMotor(_ channel: MotorChannel, slotIndex: Int = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            if slotIndex > 0, let sub = self.auxSlotEngines[slotIndex] {
                sub.testMotor(channel, slotIndex: 0)
                return
            }
            self.driveChannel(locality: channel.locality, intensity: 0.85, durationSec: 0.35)
        }
    }

    /// Apply a full 4-motor Xbox rumble command routed independently to player slot 0..3 (P1..P4).
    func applyRumble(
        gamepadIndex: UInt8 = 0,
        startDelayMs: UInt16,
        durationMs: UInt16,
        delayMs: UInt16,
        repeatCount: UInt8,
        strongMagnitude: Float,
        weakMagnitude: Float,
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        let slot = Int(gamepadIndex)
        queue.async { [weak self] in
            guard let self else { return }
            if slot > 0, !self.isChildSlotEngine, let sub = self.auxSlotEngines[slot] {
                sub.applyRumble(
                    gamepadIndex: 0,
                    startDelayMs: startDelayMs,
                    durationMs: durationMs,
                    delayMs: delayMs,
                    repeatCount: repeatCount,
                    strongMagnitude: strongMagnitude,
                    weakMagnitude: weakMagnitude,
                    leftTrigger: leftTrigger,
                    rightTrigger: rightTrigger
                )
                return
            }
            self.pendingSequenceWorkItem?.cancel()
            self.pendingSequenceWorkItem = nil

            guard self.settings.rumbleEnabled else {
                self.silenceAllLocked(stopPlayers: false)
                return
            }

            let handleGain = Float(self.settings.handleRumbleStrength)
            let triggerGain = Float(self.settings.triggerRumbleStrength)

            var leftHandle = Self.perceptualBoost(strongMagnitude, gain: handleGain, isPhoneLRA: self.isPhoneTapticFallback)
            var rightHandle = Self.perceptualBoost(weakMagnitude, gain: handleGain, isPhoneLRA: self.isPhoneTapticFallback)
            let lt = Self.perceptualBoost(leftTrigger, gain: triggerGain, isPhoneLRA: self.isPhoneTapticFallback)
            let rt = Self.perceptualBoost(rightTrigger, gain: triggerGain, isPhoneLRA: self.isPhoneTapticFallback)

            if !self.supportsTriggerRumble && self.settings.fallbackTriggerToHandles {
                let triggerFold: Float = self.isPhoneTapticFallback ? 0.85 : 0.65
                leftHandle = Self.clamp01(max(leftHandle, lt * triggerFold))
                rightHandle = Self.clamp01(max(rightHandle, rt * triggerFold))
            }

            let maxEnergy = max(leftHandle, rightHandle, lt, rt)
            if maxEnergy <= 0.005 {
                self.silenceAllLocked(stopPlayers: false)
                return
            }

            // Treat durationMs == 0 with non-zero motor values as continuous (1.5s watchdog).
            // Enforce >= 70ms floor so ERM motors reliably overcome static friction on micro-pulses.
            let rawDurationSec: Double = durationMs == 0 ? 1.5 : Double(durationMs) / 1000.0
            let durationSec = min(max(rawDurationSec, 0.070), 3.0)
            let startDelaySec = min(Double(startDelayMs) / 1000.0, 1.0)
            let gapDelaySec = min(Double(delayMs) / 1000.0, 1.0)
            let totalCycles = repeatCount >= 200 ? 20 : min(Int(repeatCount) + 1, 20)

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.fireCycle(
                    cycleIndex: 0,
                    totalCycles: totalCycles,
                    durationSec: durationSec,
                    gapDelaySec: gapDelaySec,
                    leftHandle: leftHandle,
                    rightHandle: rightHandle,
                    leftTrigger: lt,
                    rightTrigger: rt
                )
            }
            self.pendingSequenceWorkItem = work
            if startDelaySec > 0.001 {
                self.queue.asyncAfter(deadline: .now() + startDelaySec, execute: work)
            } else {
                work.perform()
            }
        }
    }

    // MARK: - Internal Implementation

    private func fireCycle(
        cycleIndex: Int,
        totalCycles: Int,
        durationSec: Double,
        gapDelaySec: Double,
        leftHandle: Float,
        rightHandle: Float,
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        guard cycleIndex < totalCycles else { return }

        let sharedHandleState: Bool = {
            if let l = channels[.leftHandle], let r = channels[.rightHandle] {
                return l === r
            }
            return false
        }()

        if sharedHandleState {
            let combined = max(leftHandle, rightHandle)
            if combined > 0.005 {
                if isPhoneTapticFallback {
                    let now = CACurrentMediaTime()
                    let energyJump = combined - lastPhoneEnergy
                    if (lastPhoneEnergy <= 0.05 || energyJump >= 0.22) && (now - lastPhonePunchTime) >= 0.065 {
                        lastPhonePunchTime = now
                        firePhoneTransientPunch(intensity: min(1.0, combined * 1.15), sharpness: rightHandle > leftHandle ? 0.85 : 0.62)
                    }
                    lastPhoneEnergy = combined
                }
                driveChannel(locality: .leftHandle, intensity: combined, durationSec: durationSec)
            } else {
                lastPhoneEnergy = 0
                muteChannel(.leftHandle)
            }
        } else {
            if leftHandle > 0.005 {
                driveChannel(locality: .leftHandle, intensity: leftHandle, durationSec: durationSec)
            } else {
                muteChannel(.leftHandle)
            }

            if rightHandle > 0.005 {
                driveChannel(locality: .rightHandle, intensity: rightHandle, durationSec: durationSec)
            } else {
                muteChannel(.rightHandle)
            }
        }

        if supportsTriggerRumble {
            if leftTrigger > 0.005 {
                driveChannel(locality: .leftTrigger, intensity: leftTrigger, durationSec: durationSec)
            } else {
                muteChannel(.leftTrigger)
            }

            if rightTrigger > 0.005 {
                driveChannel(locality: .rightTrigger, intensity: rightTrigger, durationSec: durationSec)
            } else {
                muteChannel(.rightTrigger)
            }
        }

        if cycleIndex + 1 < totalCycles {
            let nextDelay = durationSec + gapDelaySec
            let nextWork = DispatchWorkItem { [weak self] in
                self?.fireCycle(
                    cycleIndex: cycleIndex + 1,
                    totalCycles: totalCycles,
                    durationSec: durationSec,
                    gapDelaySec: gapDelaySec,
                    leftHandle: leftHandle,
                    rightHandle: rightHandle,
                    leftTrigger: leftTrigger,
                    rightTrigger: rightTrigger
                )
            }
            pendingSequenceWorkItem = nextWork
            queue.asyncAfter(deadline: .now() + nextDelay, execute: nextWork)
        }
    }

    private func bindLocked(controller: GCController?) {
        teardownLocked()
        boundController = controller
        guard let controller, let haptics = controller.haptics else {
            #if os(iOS)
            // On iPhone with touch virtual gamepad (no external controller connected),
            // fall back to iPhone's built-in Taptic Engine via CoreHaptics!
            if controller == nil && CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                if let phoneEngine = try? CHHapticEngine() {
                    phoneEngine.isAutoShutdownEnabled = false
                    let state = ChannelState(locality: .default, sharpness: 0.62, engine: phoneEngine)
                    phoneEngine.stoppedHandler = { [weak self, weak state] _ in
                        self?.queue.async {
                            state?.isEngineStarted = false
                            state?.isPlayerRunning = false
                            state?.player = nil
                            state?.currentIntensity = -1
                        }
                    }
                    phoneEngine.resetHandler = { [weak self, weak state] in
                        self?.queue.async {
                            guard let state else { return }
                            state.isEngineStarted = false
                            state.isPlayerRunning = false
                            state.player = nil
                            state.currentIntensity = -1
                            try? state.engine.start()
                            state.isEngineStarted = true
                        }
                    }
                    channels[.default] = state
                    channels[.leftHandle] = state
                    channels[.rightHandle] = state
                    isPhoneTapticFallback = true
                    supportsHandleRumble = true
                    supportsTriggerRumble = false
                    if (try? phoneEngine.start()) != nil {
                        state.isEngineStarted = true
                    }
                    Self.logger.info("haptics bound to iPhone Taptic Engine fallback (enhanced LRA)")
                    return
                }
            }
            #endif
            supportsHandleRumble = false
            supportsTriggerRumble = false
            Self.logger.info("haptics unbound (no controller or no haptics)")
            return
        }

        supportedLocalities = haptics.supportedLocalities
        supportsHandleRumble = supportedLocalities.contains(.leftHandle)
            || supportedLocalities.contains(.rightHandle)
            || supportedLocalities.contains(.handles)
            || supportedLocalities.contains(.default)
        supportsTriggerRumble = supportedLocalities.contains(.leftTrigger)
            || supportedLocalities.contains(.rightTrigger)

        let localityNames = supportedLocalities.map(\.rawValue).sorted().joined(separator: ",")
        Self.logger.info(
            "haptics bind vendor=\(controller.vendorName ?? "?", privacy: .public) handles=\(self.supportsHandleRumble, privacy: .public) triggers=\(self.supportsTriggerRumble, privacy: .public) localities=[\(localityNames, privacy: .public)]"
        )

        let desiredLocalities: [(GCHapticsLocality, Float)] = [
            (.leftHandle, 0.30),
            (.rightHandle, 0.75),
            (.leftTrigger, 0.80),
            (.rightTrigger, 0.80),
        ]

        for (locality, sharpness) in desiredLocalities {
            let resolvedLocality: GCHapticsLocality?
            if supportedLocalities.contains(locality) {
                resolvedLocality = locality
            } else if (locality == .leftHandle || locality == .rightHandle) && supportedLocalities.contains(.default) {
                resolvedLocality = .default
            } else {
                resolvedLocality = nil
            }

            guard let targetLoc = resolvedLocality else { continue }
            if let existing = channels[targetLoc] {
                channels[locality] = existing
                continue
            }
            if let engine = haptics.createEngine(withLocality: targetLoc) {
                let state = ChannelState(locality: targetLoc, sharpness: sharpness, engine: engine)
                engine.isAutoShutdownEnabled = false
                engine.stoppedHandler = { [weak self, weak state] reason in
                    self?.queue.async {
                        Self.logger.notice("haptics engine stopped loc=\(state?.locality.rawValue ?? "?", privacy: .public) reason=\(reason.rawValue, privacy: .public)")
                        state?.isEngineStarted = false
                        state?.isPlayerRunning = false
                        state?.player = nil
                        state?.currentIntensity = -1
                    }
                }
                engine.resetHandler = { [weak self, weak state] in
                    self?.queue.async {
                        guard let state else { return }
                        Self.logger.notice("haptics engine reset loc=\(state.locality.rawValue, privacy: .public)")
                        state.isEngineStarted = false
                        state.isPlayerRunning = false
                        state.player = nil
                        state.currentIntensity = -1
                        try? state.engine.start()
                        state.isEngineStarted = true
                    }
                }
                channels[targetLoc] = state
                channels[locality] = state
                do {
                    try engine.start()
                    state.isEngineStarted = true
                } catch {
                    Self.logger.error("haptics initial engine.start error loc=\(targetLoc.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Ensure the channel's long-lived simple CHHapticPatternPlayer (30s max CoreHaptics duration) is active.
    /// Refresh only if it has been running >= 25s (safely before the 30s CoreHaptics event end).
    private func ensureRunningPlayer(_ state: ChannelState, initialIntensity: Float) -> (player: CHHapticPatternPlayer, fresh: Bool)? {
        let now = CACurrentMediaTime()
        do {
            if !state.isEngineStarted {
                try state.engine.start()
                state.isEngineStarted = true
                state.isPlayerRunning = false
                state.player = nil
                state.currentIntensity = -1
            }

            if state.isPlayerRunning, let existing = state.player, (now - state.playerStartedAt) < 25.0 {
                return (existing, false)
            }

            if let old = state.player {
                try? old.stop(atTime: CHHapticTimeImmediate)
                state.player = nil
                state.isPlayerRunning = false
            }

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: state.sharpness),
                ],
                relativeTime: 0,
                duration: 30.0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try state.engine.makePlayer(with: pattern)
            let clamped = Self.clamp01(initialIntensity)
            let param = CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl,
                value: clamped,
                relativeTime: 0
            )
            try player.sendParameters([param], atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            state.player = player
            state.playerStartedAt = now
            state.isPlayerRunning = true
            state.currentIntensity = clamped
            Self.logger.info("haptics simple player started loc=\(state.locality.rawValue, privacy: .public) intensity=\(String(format: "%.2f", clamped), privacy: .public)")
            return (player, true)
        } catch {
            Self.logger.error("haptics ensureRunningPlayer error loc=\(state.locality.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state.isEngineStarted = false
            state.isPlayerRunning = false
            state.player = nil
            state.currentIntensity = -1
            return nil
        }
    }

    /// Modulate an actuator's live intensity without stopping or reallocating its XPC player.
    private func driveChannel(locality: GCHapticsLocality, intensity: Float, durationSec: Double) {
        guard let state = channels[locality] ?? channels[.default] else { return }
        let clamped = Self.clamp01(intensity)

        guard let (player, fresh) = ensureRunningPlayer(state, initialIntensity: clamped) else { return }
        do {
            if !fresh && abs(clamped - state.currentIntensity) >= 0.01 {
                let param = CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: clamped,
                    relativeTime: 0
                )
                try player.sendParameters([param], atTime: CHHapticTimeImmediate)
                state.currentIntensity = clamped
            }

            state.stopWorkItem?.cancel()
            let stopItem = DispatchWorkItem { [weak self, weak state] in
                guard let self, let state else { return }
                self.muteState(state, stopPlayer: false)
            }
            state.stopWorkItem = stopItem
            queue.asyncAfter(deadline: .now() + durationSec, execute: stopItem)
        } catch {
            Self.logger.error("haptics sendParameters error loc=\(state.locality.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state.isEngineStarted = false
            state.isPlayerRunning = false
            state.player = nil
            state.currentIntensity = -1
        }
    }

    private func muteState(_ state: ChannelState, stopPlayer: Bool) {
        state.stopWorkItem?.cancel()
        state.stopWorkItem = nil
        if stopPlayer {
            if state.isPlayerRunning {
                try? state.player?.stop(atTime: CHHapticTimeImmediate)
                state.isPlayerRunning = false
                state.player = nil
                state.currentIntensity = -1
            }
            return
        }
        if state.isPlayerRunning, let player = state.player {
            if (CACurrentMediaTime() - state.playerStartedAt) >= 29.5 {
                state.isPlayerRunning = false
                state.player = nil
                state.currentIntensity = -1
                return
            }
            if state.currentIntensity > 0 {
                let zero = CHHapticDynamicParameter(
                    parameterID: .hapticIntensityControl,
                    value: 0.0,
                    relativeTime: 0
                )
                try? player.sendParameters([zero], atTime: CHHapticTimeImmediate)
                state.currentIntensity = 0.0
            }
        }
    }

    private func muteChannel(_ locality: GCHapticsLocality) {
        guard let state = channels[locality] else { return }
        muteState(state, stopPlayer: false)
    }

    private func silenceAllLocked(stopPlayers: Bool) {
        pendingSequenceWorkItem?.cancel()
        pendingSequenceWorkItem = nil
        var visited = Set<ObjectIdentifier>()
        for state in channels.values {
            let oid = ObjectIdentifier(state)
            guard visited.insert(oid).inserted else { continue }
            muteState(state, stopPlayer: stopPlayers)
        }
    }

    private func teardownLocked() {
        silenceAllLocked(stopPlayers: true)
        var visited = Set<ObjectIdentifier>()
        for state in channels.values {
            let oid = ObjectIdentifier(state)
            guard visited.insert(oid).inserted else { continue }
            state.engine.stop(completionHandler: nil)
        }
        channels.removeAll()
        supportedLocalities.removeAll()
        boundController = nil
        isPhoneTapticFallback = false
        lastPhoneEnergy = 0
    }

    /// Fires a crisp transient kick on iPhone's linear Taptic Engine at rumble onset/spikes
    /// so impacts, gunshots, and collisions pack noticeable physical punch.
    private func firePhoneTransientPunch(intensity: Float, sharpness: Float) {
        guard let state = channels[.default] else { return }
        do {
            if !state.isEngineStarted {
                try state.engine.start()
                state.isEngineStarted = true
            }
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Self.clamp01(intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Self.clamp01(sharpness)),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try state.engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Best-effort onset punch; continuous channel continues normally
        }
    }

    /// Nonlinear perceptual boost compensating for ERM motor deadband (controllers)
    /// and LRA linear actuator headroom (iPhone Taptic Engine).
    private static func perceptualBoost(_ raw: Float, gain: Float, isPhoneLRA: Bool = false) -> Float {
        guard raw.isFinite, raw > 0.008 else { return 0 }
        let normalized = clamp01(raw)
        if isPhoneLRA {
            let curved = 0.40 + 0.60 * powf(normalized, 0.55)
            return clamp01(curved * max(gain, 0.25))
        }
        let curved = 0.14 + 0.86 * powf(normalized, 0.72)
        return clamp01(curved * gain)
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }
}
