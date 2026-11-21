import CoreHaptics
import Foundation
import GameController
import os

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

    var settings = AppSettings()

    private(set) var supportsHandleRumble: Bool = false
    private(set) var supportsTriggerRumble: Bool = false

    func bind(controller: GCController?) {
        queue.async { [weak self] in
            self?.bindLocked(controller: controller)
        }
    }

    /// Re-verify CoreHaptics engines after AVAudioSession activation/interruption.
    func prepareForStream() {
        queue.async { [weak self] in
            guard let self else { return }
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
            self?.settings = newSettings
            if !newSettings.rumbleEnabled {
                self?.silenceAllLocked(stopPlayers: true)
            }
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            self?.silenceAllLocked(stopPlayers: true)
        }
    }

    /// Trigger a short subtle confirmation pulse (e.g. menu combo activated).
    func playSubtleConfirmPulse() {
        queue.async { [weak self] in
            guard let self, self.settings.rumbleEnabled else { return }
            self.driveChannel(locality: .rightHandle, intensity: 0.45, durationSec: 0.09)
        }
    }

    /// Manual motor test for the Settings screen so user can verify each motor directly.
    func testMotor(_ channel: MotorChannel) {
        queue.async { [weak self] in
            guard let self else { return }
            self.driveChannel(locality: channel.locality, intensity: 0.85, durationSec: 0.35)
        }
    }

    /// Apply a full 4-motor Xbox rumble command coming from Rust nano-rs.
    func applyRumble(
        startDelayMs: UInt16,
        durationMs: UInt16,
        delayMs: UInt16,
        repeatCount: UInt8,
        strongMagnitude: Float,
        weakMagnitude: Float,
        leftTrigger: Float,
        rightTrigger: Float
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSequenceWorkItem?.cancel()
            self.pendingSequenceWorkItem = nil

            guard self.settings.rumbleEnabled else {
                self.silenceAllLocked(stopPlayers: false)
                return
            }

            let handleGain = Float(self.settings.handleRumbleStrength)
            let triggerGain = Float(self.settings.triggerRumbleStrength)

            var leftHandle = Self.perceptualBoost(strongMagnitude, gain: handleGain)
            var rightHandle = Self.perceptualBoost(weakMagnitude, gain: handleGain)
            let lt = Self.perceptualBoost(leftTrigger, gain: triggerGain)
            let rt = Self.perceptualBoost(rightTrigger, gain: triggerGain)

            if !self.supportsTriggerRumble && self.settings.fallbackTriggerToHandles {
                leftHandle = Self.clamp01(max(leftHandle, lt * 0.65))
                rightHandle = Self.clamp01(max(rightHandle, rt * 0.65))
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
                driveChannel(locality: .leftHandle, intensity: combined, durationSec: durationSec)
            } else {
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
    }

    /// Nonlinear perceptual boost compensating for Xbox ERM motor static-friction deadband over Bluetooth.
    private static func perceptualBoost(_ raw: Float, gain: Float) -> Float {
        guard raw.isFinite, raw > 0.008 else { return 0 }
        let normalized = clamp01(raw)
        let curved = 0.14 + 0.86 * powf(normalized, 0.72)
        return clamp01(curved * gain)
    }

    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }
}
