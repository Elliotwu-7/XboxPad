import CoreImage
import CoreMedia
import CoreVideo
import Metal
import MetalFX
import os
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import VideoToolbox

enum MetalFXSupport {
    static var isSupported: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }
}

/// Ultra-low-latency H.264 Annex-B -> VideoToolbox (`RealTime = true`, synchronous zero-queue decode)
/// -> Decoupled Zero-Copy Metal `CAMetalLayer` renderer (`maximumDrawableCount = 3`, 120Hz ProMotion).
///
/// Key architectural invariant:
/// - `decodeQueue` ONLY runs VideoToolbox hardware decode (~1-2ms) and publishes the decoded
///   `CVPixelBuffer` into a lock-protected latest-frame slot. It NEVER blocks on `CAMetalLayer.nextDrawable()`.
/// - `renderQueue` consumes ONLY the newest `CVPixelBuffer` and renders it via zero-copy
///   `CVMetalTextureCache` -> `CAMetalLayer`, eliminating both VSync backpressure and frame queue buildup.
final class H264StreamRenderer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "video")

    private struct RenderUniforms {
        var scaleX: Float
        var scaleY: Float
        var isFullRange: Float
        var isBT709: Float
        var texelSizeX: Float
        var texelSizeY: Float
        var sharpenStrength: Float
        var hdrMode: Float // 0 = SDR, 1 = HDR active
        var edrHeadroom: Float
        var hdrMaxPeak: Float
        var hdrContrast: Float
        var hdrSaturation: Float
        var hdrKnee: Float
        var debandStrength: Float
        var pad1: Float
        var pad2: Float
        var shadowLift: Float
        var brightness: Float
        var contrast: Float
        var saturation: Float
    }

    private let decodeQueue = DispatchQueue(label: "com.elliot.xboxpad.video.decode", qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.elliot.xboxpad.video.render", qos: .userInteractive)

    // Latest-frame handoff slot + auto-adaptive AWDL/wireless burst frame pacer + 120Hz VSync anchor
    private var frameLock = os_unfair_lock_s()
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestPrevPixelBuffer: CVPixelBuffer?
    private var latestIsInterpolated: Bool = false
    private var pendingPresentTime: CFTimeInterval = 0
    private var latestFrameSerial: UInt64 = 0
    private var renderedFrameSerial: UInt64 = 0
    private var renderScheduled = false
    private var isBackgroundedLocked = false
    private var aspectModeLocked: VideoAspectMode = .fit
    private var sharpeningLevelLocked: VideoSharpeningLevel = .light
    private var hdrToneModeLocked: VideoHDRToneMode = .off
    private var debandingEnabledLocked: Bool = true
    private var metalFXEnabledLocked: Bool = true
    private var shadowLiftLocked: Float = 0.0
    private var brightnessLocked: Float = 0.0
    private var contrastLocked: Float = 1.0
    private var saturationLocked: Float = 1.0
    private var thermalEDRMultiplierLocked: Float = 1.0
    private var isMetalFXActiveLocked: Bool = false
    private var currentEDRHeadroomLocked: Float = 1.0
    private var pacingModeLocked: VideoFramePacingMode = .auto
    private var interpolationEnabledLocked: Bool = false
    private var pacedQueue: [(pb: CVPixelBuffer, arrivedAt: CFTimeInterval)] = []
    private var prevDisplayedRealPB: CVPixelBuffer?
    private var lastDisplayedRealPB: CVPixelBuffer?
    private var pendingRealPBForSecondSlot: (pb: CVPixelBuffer, arrivedAt: CFTimeInterval)?
    private var latestPipelineLatencyMsLocked: Double = 0
    private var lastDecodedArrivalTime: CFTimeInterval = 0
    private var lastBurstSpikeTime: CFTimeInterval = 0
    private var smoothedPeakGapMs: Double = 16.7
    private var lastPacedPopTime: CFTimeInterval = 0
    private var lastRealDisplayTimeLocked: CFTimeInterval = 0
    private var lastDisplayTickTimeLocked: CFTimeInterval = 0
    private var smoothedDisplayHzLocked: Double = 120.0
    private var latestInterpPhaseLocked: Float = 0.5
    private var activePacingTargetDepth: Int = 0
    private var queuedIdrSerial: UInt64 = 0
    private var renderedCountForCacheFlush: UInt64 = 0
    private var presentedFramesInWindow: Int = 0
    private var fpsWindowStartTime: CFTimeInterval = 0
    private var measuredDisplayFpsLocked: Double = 0
    private var interpolatedActiveLocked: Bool = false

    // VideoToolbox state (accessed exclusively on `decodeQueue`)
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var hasRenderedFirstFrame = false
    private var waitingForKeyframe = true
    private var lastKeyframeRequestTime: CFTimeInterval = 0
    private var submittedFrameCount: UInt64 = 0
    private var decodedFrameCount: UInt64 = 0
    private var decodeErrorCount: UInt64 = 0

    // Metal state (accessed exclusively on `renderQueue`)
    private weak var metalLayer: CAMetalLayer?
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var interpPipelineState: MTLRenderPipelineState?
    private var blitPipelineState: MTLRenderPipelineState?
    private var opticalFlowEngine: MetalOpticalFlowEngine?
    private var metalFXScaler: MTLFXSpatialScaler?
    private var metalFXInputTex: MTLTexture?
    private var metalFXOutputTex: MTLTexture?
    private var metalFXSig: (Int, Int, Int, Int, Bool) = (0, 0, 0, 0, false)
    private var textureCache: CVMetalTextureCache?
    private var interpRenderedCount: UInt64 = 0
    private lazy var screenshotCIContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev)
        }
        return CIContext()
    }()

    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    var onNeedKeyframe: (() -> Void)?
    var onFirstFrameRendered: (() -> Void)?
    var onDecodeTiming: ((Double) -> Void)?
    private var decodedFrameTap: (@Sendable (CVPixelBuffer) -> Void)?

    func setDecodedFrameTap(_ tap: (@Sendable (CVPixelBuffer) -> Void)?) {
        decodeQueue.async { [weak self] in
            self?.decodedFrameTap = tap
        }
    }

    init() {
        setupAppLifecycleObservers()
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func attach(metalLayer: CAMetalLayer, aspectMode: VideoAspectMode) {
        let box = UncheckedMetalLayerBox(layer: metalLayer)

        os_unfair_lock_lock(&frameLock)
        let hadExistingFrame = latestPixelBuffer != nil
        aspectModeLocked = aspectMode
        if !hadExistingFrame {
            latestPixelBuffer = nil
            latestPrevPixelBuffer = nil
            latestIsInterpolated = false
            pendingPresentTime = 0
            latestFrameSerial = 0
            renderedFrameSerial = 0
            renderScheduled = false
            pacedQueue.removeAll(keepingCapacity: true)
            prevDisplayedRealPB = nil
            lastDisplayedRealPB = nil
            pendingRealPBForSecondSlot = nil
            lastDecodedArrivalTime = 0
            lastBurstSpikeTime = 0
            smoothedPeakGapMs = 16.7
            lastPacedPopTime = 0
            lastRealDisplayTimeLocked = 0
            lastDisplayTickTimeLocked = 0
            smoothedDisplayHzLocked = 120.0
            latestInterpPhaseLocked = 0.5
            activePacingTargetDepth = 0
            presentedFramesInWindow = 0
            fpsWindowStartTime = 0
            measuredDisplayFpsLocked = 0
            latestPipelineLatencyMsLocked = 0
            interpolatedActiveLocked = false
        } else {
            renderedFrameSerial = latestFrameSerial &- 1
        }
        os_unfair_lock_unlock(&frameLock)

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.metalLayer = box.layer
            self.metalFXScaler = nil
            self.metalFXInputTex = nil
            self.metalFXOutputTex = nil
            self.metalFXSig = (0, 0, 0, 0, false)
            self.setupMetalLocked(layer: box.layer)
            if hadExistingFrame {
                self.triggerRender(forceRedraw: true)
            }
        }

        if !hadExistingFrame {
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.waitingForKeyframe = true
                self.hasRenderedFirstFrame = false
                self.submittedFrameCount = 0
                self.decodedFrameCount = 0
                self.decodeErrorCount = 0
            }
        }
    }

    func updateAspectMode(_ mode: VideoAspectMode) {
        os_unfair_lock_lock(&frameLock)
        let changed = aspectModeLocked != mode
        aspectModeLocked = mode
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func updateSharpeningLevel(_ level: VideoSharpeningLevel) {
        os_unfair_lock_lock(&frameLock)
        let changed = sharpeningLevelLocked != level
        sharpeningLevelLocked = level
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func updateHDRToneMode(_ mode: VideoHDRToneMode) {
        os_unfair_lock_lock(&frameLock)
        let changed = hdrToneModeLocked != mode
        hdrToneModeLocked = mode
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func updateEDRHeadroom(_ headroom: Float) {
        let clamped = max(min(headroom, 4.0), 1.0)
        os_unfair_lock_lock(&frameLock)
        currentEDRHeadroomLocked = clamped
        os_unfair_lock_unlock(&frameLock)
    }

    func updateDebanding(_ enabled: Bool) {
        os_unfair_lock_lock(&frameLock)
        let changed = debandingEnabledLocked != enabled
        debandingEnabledLocked = enabled
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func updateMetalFX(_ enabled: Bool) {
        let effective = enabled && MetalFXSupport.isSupported
        os_unfair_lock_lock(&frameLock)
        let changed = metalFXEnabledLocked != effective
        metalFXEnabledLocked = effective
        if !effective {
            isMetalFXActiveLocked = false
        }
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func updateThermalEDRMultiplier(_ multiplier: Float) {
        let clamped = max(min(multiplier, 1.0), 0.45)
        os_unfair_lock_lock(&frameLock)
        thermalEDRMultiplierLocked = clamped
        os_unfair_lock_unlock(&frameLock)
    }

    func updateColorGrading(shadowLift: Double, brightness: Double, contrast: Double, saturation: Double) {
        let sl = Float(max(min(shadowLift, 0.5), 0.0))
        let br = Float(max(min(brightness, 0.35), -0.35))
        let ct = Float(max(min(contrast, 1.5), 0.6))
        let st = Float(max(min(saturation, 1.6), 0.4))
        os_unfair_lock_lock(&frameLock)
        let changed = abs(shadowLiftLocked - sl) > 0.001
            || abs(brightnessLocked - br) > 0.001
            || abs(contrastLocked - ct) > 0.001
            || abs(saturationLocked - st) > 0.001
        shadowLiftLocked = sl
        brightnessLocked = br
        contrastLocked = ct
        saturationLocked = st
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if changed && hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    var isMetalFXActive: Bool {
        os_unfair_lock_lock(&frameLock)
        let active = metalFXEnabledLocked && isMetalFXActiveLocked
        os_unfair_lock_unlock(&frameLock)
        return active
    }

    /// Captures a full-resolution lossless screenshot from the newest decoded video frame
    /// without stalling the 120Hz render pipeline.
    func captureCurrentFrameImage(completion: @escaping @Sendable (CGImage?) -> Void) {
        os_unfair_lock_lock(&frameLock)
        let pb = latestPixelBuffer
        os_unfair_lock_unlock(&frameLock)

        guard let pb else {
            completion(nil)
            return
        }
        let pbBox = UncheckedPixelBufferBox(pb: pb)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            let ciImage = CIImage(cvPixelBuffer: pbBox.pb)
            let rect = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pbBox.pb),
                height: CVPixelBufferGetHeight(pbBox.pb)
            )
            completion(self.screenshotCIContext.createCGImage(ciImage, from: rect))
        }
    }

    var isHardwareInterpolationActive: Bool {
        os_unfair_lock_lock(&frameLock)
        let active = interpolationEnabledLocked && interpolatedActiveLocked
        os_unfair_lock_unlock(&frameLock)
        return active
    }

    var measuredDisplayFps: Double {
        os_unfair_lock_lock(&frameLock)
        let fps = measuredDisplayFpsLocked
        os_unfair_lock_unlock(&frameLock)
        return fps
    }

    var latestPipelineLatencyMs: Double {
        os_unfair_lock_lock(&frameLock)
        let ms = latestPipelineLatencyMsLocked
        os_unfair_lock_unlock(&frameLock)
        return ms
    }

    func updateFramePacingMode(_ mode: VideoFramePacingMode) {
        os_unfair_lock_lock(&frameLock)
        pacingModeLocked = mode
        if mode == .immediate && !interpolationEnabledLocked {
            pacedQueue.removeAll(keepingCapacity: true)
            activePacingTargetDepth = 0
        }
        os_unfair_lock_unlock(&frameLock)
    }

    func updateFrameInterpolation(_ enabled: Bool) {
        let effective = enabled && LocalFrameInterpolationSupport.isSupported
        os_unfair_lock_lock(&frameLock)
        let changed = interpolationEnabledLocked != effective
        interpolationEnabledLocked = effective
        if !effective {
            pendingRealPBForSecondSlot = nil
            interpolatedActiveLocked = false
        }
        os_unfair_lock_unlock(&frameLock)
        if changed {
            Self.logger.info("video 120fps metal optical-flow interpolation toggled -> \(effective, privacy: .public)")
        }
    }

    /// Driven by `CADisplayLink` at the monitor's native VSync (60Hz / 75Hz / 90Hz / 100Hz / 120Hz / 144Hz).
    /// - 60Hz pacing mode: pops 1 real decoded frame every 16.67ms VSync slot.
    /// - High-refresh Metal optical-flow mode:
    ///     * >= 112Hz (iPad Pro / MacBook Pro 120Hz / 144Hz+): alternates exact midpoint (t=0.5) & real frame -> locked 120fps.
    ///     * 68..112Hz (e.g. 75Hz / 90Hz / 100Hz Mac monitors): presents real 60Hz frames on time and synthesizes
    ///       exact fractional-phase optical-flow frames on every intermediate VSync slot -> locked 75fps / 100fps!
    func handleDisplayTick(now: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        var shouldSchedule = false

        os_unfair_lock_lock(&frameLock)
        if lastDisplayTickTimeLocked > 0 {
            let dt = now - lastDisplayTickTimeLocked
            if dt > 0.002 && dt < 0.05 {
                let instHz = 1.0 / dt
                smoothedDisplayHzLocked = smoothedDisplayHzLocked * 0.88 + instHz * 0.12
            }
        }
        lastDisplayTickTimeLocked = now

        if !isBackgroundedLocked {
            if interpolationEnabledLocked {
                if smoothedDisplayHzLocked >= 112.0 {
                    // 120Hz+ display path: strict alternating (Midpoint t=0.5 -> Real Frame)
                    if let pendingReal = pendingRealPBForSecondSlot {
                        pendingRealPBForSecondSlot = nil
                        prevDisplayedRealPB = lastDisplayedRealPB
                        lastDisplayedRealPB = pendingReal.pb
                        lastPacedPopTime = now
                        lastRealDisplayTimeLocked = now
                        latestPixelBuffer = pendingReal.pb
                        latestPrevPixelBuffer = nil
                        latestIsInterpolated = false
                        latestInterpPhaseLocked = 0.5
                        pendingPresentTime = targetTimestamp
                        latestPipelineLatencyMsLocked = max((targetTimestamp - pendingReal.arrivedAt) * 1000.0, 0.0)
                        latestFrameSerial &+= 1
                        if !renderScheduled {
                            renderScheduled = true
                            shouldSchedule = true
                        }
                    } else if !pacedQueue.isEmpty {
                        let target = max(activePacingTargetDepth, 1)
                        let shouldCatchUp = pacedQueue.count > target
                        let nextEntry = pacedQueue.removeFirst()
                        if !shouldCatchUp, let prevReal = lastDisplayedRealPB {
                            pendingRealPBForSecondSlot = nextEntry
                            lastPacedPopTime = now
                            latestPixelBuffer = nextEntry.pb
                            latestPrevPixelBuffer = prevReal
                            latestIsInterpolated = true
                            latestInterpPhaseLocked = 0.5
                            interpolatedActiveLocked = true
                            pendingPresentTime = targetTimestamp
                            latestPipelineLatencyMsLocked = max((targetTimestamp - nextEntry.arrivedAt) * 1000.0, 0.0)
                            latestFrameSerial &+= 1
                            if !renderScheduled {
                                renderScheduled = true
                                shouldSchedule = true
                            }
                        } else {
                            prevDisplayedRealPB = lastDisplayedRealPB
                            lastDisplayedRealPB = nextEntry.pb
                            lastPacedPopTime = now
                            lastRealDisplayTimeLocked = now
                            latestPixelBuffer = nextEntry.pb
                            latestPrevPixelBuffer = nil
                            latestIsInterpolated = false
                            latestInterpPhaseLocked = 0.5
                            pendingPresentTime = targetTimestamp
                            latestPipelineLatencyMsLocked = max((targetTimestamp - nextEntry.arrivedAt) * 1000.0, 0.0)
                            latestFrameSerial &+= 1
                            if !renderScheduled {
                                renderScheduled = true
                                shouldSchedule = true
                            }
                        }
                    }
                } else {
                    // 75Hz / 90Hz / 100Hz (and any non-120Hz high-refresh monitor) path:
                    // Present real 60Hz frames on cadence, and synthesize exact fractional optical-flow
                    // frames on every intermediate VSync slot so the queue never backs up!
                    pendingRealPBForSecondSlot = nil
                    let target = max(activePacingTargetDepth, 1)
                    let realDue = !pacedQueue.isEmpty && (
                        lastRealDisplayTimeLocked == 0
                            || (now - lastRealDisplayTimeLocked) >= 0.0142
                            || pacedQueue.count > target
                    )
                    if realDue {
                        let nextEntry = pacedQueue.removeFirst()
                        prevDisplayedRealPB = lastDisplayedRealPB
                        lastDisplayedRealPB = nextEntry.pb
                        lastPacedPopTime = now
                        lastRealDisplayTimeLocked = now
                        latestPixelBuffer = nextEntry.pb
                        latestPrevPixelBuffer = nil
                        latestIsInterpolated = false
                        latestInterpPhaseLocked = 0.5
                        pendingPresentTime = targetTimestamp
                        latestPipelineLatencyMsLocked = max((targetTimestamp - nextEntry.arrivedAt) * 1000.0, 0.0)
                        latestFrameSerial &+= 1
                        if !renderScheduled {
                            renderScheduled = true
                            shouldSchedule = true
                        }
                    } else if let prevReal = prevDisplayedRealPB,
                              let currReal = lastDisplayedRealPB,
                              lastRealDisplayTimeLocked > 0 {
                        let elapsed = now - lastRealDisplayTimeLocked
                        let phase = Float(min(max(elapsed / (1.0 / 60.0), 0.22), 0.78))
                        latestPixelBuffer = currReal
                        latestPrevPixelBuffer = prevReal
                        latestIsInterpolated = true
                        latestInterpPhaseLocked = phase
                        interpolatedActiveLocked = true
                        pendingPresentTime = targetTimestamp
                        latestFrameSerial &+= 1
                        if !renderScheduled {
                            renderScheduled = true
                            shouldSchedule = true
                        }
                    }
                }
            } else if !pacedQueue.isEmpty {
                let depth = pacedQueue.count
                let target = max(activePacingTargetDepth, 1)
                let stepSec: CFTimeInterval
                if depth > target {
                    stepSec = 0.0125 // brisk catch-up so queue returns to target quickly
                } else if depth < target {
                    stepSec = 0.0185 // gentle cushion rebuild without visible hitch
                } else {
                    stepSec = 1.0 / 60.0 // locked 60.0Hz
                }
                if lastPacedPopTime == 0 || (now - lastPacedPopTime) >= (stepSec - 0.0025) {
                    let nextEntry = pacedQueue.removeFirst()
                    lastDisplayedRealPB = nextEntry.pb
                    lastPacedPopTime = now
                    latestPixelBuffer = nextEntry.pb
                    latestPrevPixelBuffer = nil
                    latestIsInterpolated = false
                    pendingPresentTime = targetTimestamp
                    latestPipelineLatencyMsLocked = max((targetTimestamp - nextEntry.arrivedAt) * 1000.0, 0.0)
                    latestFrameSerial &+= 1
                    if !renderScheduled {
                        renderScheduled = true
                        shouldSchedule = true
                    }
                }
            }
        }
        os_unfair_lock_unlock(&frameLock)

        if shouldSchedule {
            renderQueue.async { [weak self] in
                self?.drainRenderLoop()
            }
        }
    }

    func handleDrawableSizeChanged() {
        os_unfair_lock_lock(&frameLock)
        let hasFrame = latestPixelBuffer != nil
        os_unfair_lock_unlock(&frameLock)

        if hasFrame {
            triggerRender(forceRedraw: true)
        }
    }

    func detach() {
        os_unfair_lock_lock(&frameLock)
        latestPixelBuffer = nil
        latestPrevPixelBuffer = nil
        latestIsInterpolated = false
        pendingPresentTime = 0
        latestFrameSerial = 0
        renderedFrameSerial = 0
        renderScheduled = false
        pacedQueue.removeAll(keepingCapacity: false)
        prevDisplayedRealPB = nil
        lastDisplayedRealPB = nil
        pendingRealPBForSecondSlot = nil
        lastDecodedArrivalTime = 0
        lastBurstSpikeTime = 0
        smoothedPeakGapMs = 16.7
        lastPacedPopTime = 0
        lastRealDisplayTimeLocked = 0
        lastDisplayTickTimeLocked = 0
        activePacingTargetDepth = 0
        interpolatedActiveLocked = false
        os_unfair_lock_unlock(&frameLock)

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateSessionLocked()
            self.cachedSPS = nil
            self.cachedPPS = nil
            self.formatDescription = nil
            self.waitingForKeyframe = true
            self.hasRenderedFirstFrame = false
        }

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.metalLayer = nil
            if let cache = self.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
        }
    }

    func resetForForeground() {
        setBackgrounded(false)
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateSessionLocked()
            self.waitingForKeyframe = true
            self.requestKeyframeThrottled()
        }
    }

    /// Full reset for manual/automatic stream reconnect so the next decoded frame
    /// reliably fires `onFirstFrameRendered` and dismisses the loading overlay.
    func resetForReconnect() {
        os_unfair_lock_lock(&frameLock)
        latestPixelBuffer = nil
        latestPrevPixelBuffer = nil
        latestIsInterpolated = false
        pendingPresentTime = 0
        latestFrameSerial = 0
        renderedFrameSerial = 0
        renderScheduled = false
        pacedQueue.removeAll(keepingCapacity: false)
        prevDisplayedRealPB = nil
        lastDisplayedRealPB = nil
        pendingRealPBForSecondSlot = nil
        lastDecodedArrivalTime = 0
        lastBurstSpikeTime = 0
        smoothedPeakGapMs = 16.7
        lastPacedPopTime = 0
        lastRealDisplayTimeLocked = 0
        lastDisplayTickTimeLocked = 0
        activePacingTargetDepth = 0
        interpolatedActiveLocked = false
        os_unfair_lock_unlock(&frameLock)

        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.invalidateSessionLocked()
            self.waitingForKeyframe = true
            self.hasRenderedFirstFrame = false
            self.formatDescription = nil
            self.cachedSPS = nil
            self.cachedPPS = nil
            self.submittedFrameCount = 0
            self.decodedFrameCount = 0
            self.decodeErrorCount = 0
        }
    }

    /// Ensure the next rendered frame fires `onFirstFrameRendered` without clearing the current picture.
    func markAwaitingFirstFrame() {
        decodeQueue.async { [weak self] in
            self?.hasRenderedFirstFrame = false
        }
    }

    /// Receives an H.264 Annex-B Access Unit directly from Rust nano-rs.
    func enqueueAccessUnit(data: Data, ptsUs: Int64, keyframe: Bool) {
        os_unfair_lock_lock(&frameLock)
        if keyframe {
            queuedIdrSerial &+= 1
        }
        let targetIdrSerial = queuedIdrSerial
        os_unfair_lock_unlock(&frameLock)

        decodeQueue.async { [weak self] in
            self?.processAccessUnitLocked(
                data: data,
                ptsUs: ptsUs,
                keyframe: keyframe,
                enqueuedIdrSerial: targetIdrSerial
            )
        }
    }

    // MARK: - App Lifecycle (prevent background GPU submission crashes)

    private func setBackgrounded(_ value: Bool) {
        os_unfair_lock_lock(&frameLock)
        isBackgroundedLocked = value
        os_unfair_lock_unlock(&frameLock)
    }

    private func isBackgrounded() -> Bool {
        os_unfair_lock_lock(&frameLock)
        let bg = isBackgroundedLocked
        os_unfair_lock_unlock(&frameLock)
        return bg
    }

    private func setupAppLifecycleObservers() {
        #if os(iOS)
        let resignName = UIApplication.willResignActiveNotification
        let activeName = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        // On macOS, keep rendering even when another window briefly takes focus;
        // only track app hide/unhide so windowed multi-tasking never freezes video!
        let resignName = NSApplication.didHideNotification
        let activeName = NSApplication.didUnhideNotification
        #endif

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: resignName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setBackgrounded(true)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: activeName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let wasBackgrounded = self.isBackgrounded()
            self.setBackgrounded(false)
            if wasBackgrounded {
                self.decodeQueue.async { [weak self] in
                    guard let self else { return }
                    self.waitingForKeyframe = true
                    self.requestKeyframeThrottled()
                }
            }
        }
    }

    // MARK: - H.264 Decode Pipeline (`decodeQueue` only, NEVER blocks on Metal!)

    private func processAccessUnitLocked(
        data: Data,
        ptsUs: Int64,
        keyframe: Bool,
        enqueuedIdrSerial: UInt64
    ) {
        guard !data.isEmpty, !isBackgrounded() else { return }

        // If a newer IDR keyframe is already queued behind stale P-frames during a burst,
        // skip decoding the obsolete P-frames cleanly so display latency snaps back to 0ms.
        if !keyframe {
            os_unfair_lock_lock(&frameLock)
            let latestIdr = queuedIdrSerial
            os_unfair_lock_unlock(&frameLock)
            if enqueuedIdrSerial < latestIdr {
                return
            }
        }

        let startTime = CACurrentMediaTime()
        let nalRanges = scanAnnexBNALRanges(in: data)
        guard !nalRanges.isEmpty else { return }

        var newSPS: Data?
        var newPPS: Data?
        var pictureRanges: [Range<Int>] = []
        pictureRanges.reserveCapacity(nalRanges.count)
        var containsIDR = keyframe

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            for range in nalRanges {
                guard range.count > 0 else { continue }
                let nalType = base[range.lowerBound] & 0x1F
                switch nalType {
                case 7: // SPS
                    newSPS = Data(bytes: base + range.lowerBound, count: range.count)
                case 8: // PPS
                    newPPS = Data(bytes: base + range.lowerBound, count: range.count)
                case 5: // IDR slice
                    containsIDR = true
                    pictureRanges.append(range)
                case 1: // Non-IDR slice
                    pictureRanges.append(range)
                case 6, 9: // SEI, AUD - skip for cleaner VideoToolbox low-latency behavior
                    continue
                default:
                    pictureRanges.append(range)
                }
            }
        }

        var paramsChanged = false
        if let sps = newSPS, sps != cachedSPS {
            cachedSPS = sps
            paramsChanged = true
        }
        if let pps = newPPS, pps != cachedPPS {
            cachedPPS = pps
            paramsChanged = true
        }

        if paramsChanged || formatDescription == nil {
            if let sps = cachedSPS, let pps = cachedPPS {
                if let desc = createFormatDescription(sps: sps, pps: pps) {
                    formatDescription = desc
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let profileIdc: UInt8 = sps.count >= 2 ? sps[1] : 0
                    let levelIdc: UInt8 = sps.count >= 4 ? sps[3] : 0
                    Self.logger.info(
                        "video sps/pps ready \(dims.width, privacy: .public)x\(dims.height, privacy: .public) profileIdc=\(profileIdc, privacy: .public) levelIdc=\(levelIdc, privacy: .public)"
                    )
                    recreateDecompressionSessionLocked(formatDescription: desc)
                }
            }
        }

        guard let formatDesc = formatDescription else {
            requestKeyframeThrottled()
            return
        }

        if decompressionSession == nil {
            recreateDecompressionSessionLocked(formatDescription: formatDesc)
        }
        guard let session = decompressionSession else {
            requestKeyframeThrottled()
            return
        }

        if waitingForKeyframe {
            guard containsIDR else {
                requestKeyframeThrottled()
                return
            }
            waitingForKeyframe = false
        }

        guard !pictureRanges.isEmpty else { return }

        guard let sampleBuffer = createSampleBufferDirect(
            annexBData: data,
            pictureRanges: pictureRanges,
            formatDescription: formatDesc,
            ptsUs: ptsUs,
            isKeyframe: containsIDR
        ) else {
            return
        }

        submittedFrameCount += 1
        var infoFlags = VTDecodeInfoFlags()
        var decodedPixelBuffer: CVPixelBuffer?
        var callbackStatus: OSStatus = noErr

        // Synchronous real-time hardware decode (flags: []) -> ~1-2ms, zero VideoToolbox queue buildup
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { status, _, imageBuffer, _, _ in
            callbackStatus = status
            if status == noErr, let pb = imageBuffer {
                decodedPixelBuffer = pb
            }
        }

        if decodeStatus != noErr || callbackStatus != noErr {
            decodeErrorCount += 1
            let errCode = decodeStatus != noErr ? decodeStatus : callbackStatus
            if decodeErrorCount <= 5 || decodeErrorCount % 30 == 0 {
                Self.logger.warning(
                    "video vt decode error #\(self.decodeErrorCount, privacy: .public) status=\(errCode, privacy: .public) idr=\(containsIDR, privacy: .public) -> recover"
                )
            }
            if decodeStatus == kVTInvalidSessionErr || decodeStatus == kVTVideoDecoderMalfunctionErr {
                invalidateSessionLocked()
            }
            waitingForKeyframe = true
            requestKeyframeThrottled()
            return
        }

        guard let pixelBuffer = decodedPixelBuffer else {
            if submittedFrameCount <= 5 {
                Self.logger.notice(
                    "video vt frame buffered submitted=\(self.submittedFrameCount, privacy: .public) decoded=\(self.decodedFrameCount, privacy: .public)"
                )
            }
            return
        }

        decodedFrameCount += 1
        let now = CACurrentMediaTime()
        let decodeMs = (now - startTime) * 1000.0
        if decodedFrameCount <= 3 {
            let lag = submittedFrameCount >= decodedFrameCount ? submittedFrameCount - decodedFrameCount : 0
            Self.logger.info(
                "video vt frame #\(self.decodedFrameCount, privacy: .public) lagFrames=\(lag, privacy: .public) decodeMs=\(String(format: "%.2f", decodeMs), privacy: .public)"
            )
        }
        onDecodeTiming?(decodeMs)
        decodedFrameTap?(pixelBuffer)

        publishDecodedFrame(pixelBuffer, arrivalTime: now)

        if !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            onFirstFrameRendered?()
        }
    }

    private func publishDecodedFrame(_ pixelBuffer: CVPixelBuffer, arrivalTime now: CFTimeInterval) {
        // Strictly in-order decoded frame publication:
        // - Clean LAN/Wi-Fi (no burst for 8s & 120Hz OFF) -> 0-frame zero-latency direct render
        // - Bursty Wi-Fi / AWDL / 5G hotspot -> 2-4 frame FIFO paced cleanly at 60Hz VSync
        // - 120fps Metal Optical Flow ON -> 2-3 frame FIFO drained in strict (Interp -> Real) 120Hz VSync pairs
        var shouldSchedule = false
        var pacingLogMessage: String?

        os_unfair_lock_lock(&frameLock)
        if lastDecodedArrivalTime > 0 {
            let gapMs = min(max((now - lastDecodedArrivalTime) * 1000.0, 0.0), 120.0)
            if gapMs >= 28.0 {
                lastBurstSpikeTime = now
            }
            smoothedPeakGapMs = max(gapMs, smoothedPeakGapMs * 0.9985)
        }
        lastDecodedArrivalTime = now

        let prevTarget = activePacingTargetDepth
        let withinBurstHold = lastBurstSpikeTime > 0 && (now - lastBurstSpikeTime) < 6.0

        let base60Target: Int
        switch pacingModeLocked {
        case .immediate:
            base60Target = 0
        case .smooth:
            base60Target = min(max(Int(ceil((smoothedPeakGapMs - 14.0) / 16.67)), 2), 3)
        case .auto:
            if smoothedPeakGapMs >= 26.0 || (prevTarget > 0 && (withinBurstHold || smoothedPeakGapMs >= 22.0)) {
                base60Target = min(max(Int(ceil((smoothedPeakGapMs - 18.0) / 16.67)), 1), 3)
            } else {
                base60Target = 0
            }
        }

        // 120Hz interpolation only needs 1 frame (16.7ms) on clean LAN, expanding to 2-3 frames only during real bursts
        let newTarget = interpolationEnabledLocked ? max(base60Target, 1) : base60Target
        activePacingTargetDepth = newTarget

        if (prevTarget == 0) != (newTarget == 0) || abs(prevTarget - newTarget) >= 2 {
            let modeDesc: String
            if interpolationEnabledLocked {
                modeDesc = "120hz-metal-interp(depth=\(newTarget))"
            } else if newTarget > 0 {
                modeDesc = "burst-smooth(depth=\(newTarget))"
            } else {
                modeDesc = "zero-latency-direct"
            }
            pacingLogMessage = "video pacing switched -> \(modeDesc) peakGapMs=\(String(format: "%.1f", smoothedPeakGapMs))"
        }

        if newTarget == 0 && pacedQueue.isEmpty && !interpolationEnabledLocked {
            lastDisplayedRealPB = pixelBuffer
            latestPixelBuffer = pixelBuffer
            latestPrevPixelBuffer = nil
            latestIsInterpolated = false
            pendingPresentTime = 0
            latestPipelineLatencyMsLocked = 0.0
            latestFrameSerial &+= 1
            if !renderScheduled {
                renderScheduled = true
                shouldSchedule = true
            }
        } else {
            pacedQueue.append((pb: pixelBuffer, arrivedAt: now))
            let effectiveCap = max(newTarget + 2, 4)
            if pacedQueue.count > effectiveCap {
                let trimTo = max(newTarget, 1)
                pacedQueue.removeFirst(pacedQueue.count - trimTo)
            }
            if latestPixelBuffer == nil && !pacedQueue.isEmpty {
                let firstEntry = pacedQueue.removeFirst()
                lastDisplayedRealPB = firstEntry.pb
                lastPacedPopTime = now
                latestPixelBuffer = firstEntry.pb
                latestPrevPixelBuffer = nil
                latestIsInterpolated = false
                pendingPresentTime = 0
                latestPipelineLatencyMsLocked = 0.0
                latestFrameSerial &+= 1
                if !renderScheduled {
                    renderScheduled = true
                    shouldSchedule = true
                }
            }
        }
        os_unfair_lock_unlock(&frameLock)

        if let msg = pacingLogMessage {
            Self.logger.info("\(msg, privacy: .public)")
        }

        if shouldSchedule {
            renderQueue.async { [weak self] in
                self?.drainRenderLoop()
            }
        }
    }

    private func triggerRender(forceRedraw: Bool) {
        os_unfair_lock_lock(&frameLock)
        if forceRedraw {
            renderedFrameSerial = latestFrameSerial &- 1
        }
        let shouldSchedule = !renderScheduled && latestPixelBuffer != nil
        if shouldSchedule {
            renderScheduled = true
        }
        os_unfair_lock_unlock(&frameLock)

        if shouldSchedule {
            renderQueue.async { [weak self] in
                self?.drainRenderLoop()
            }
        }
    }

    /// Runs on `renderQueue` — always renders ONLY the newest available frame, never blocking `decodeQueue`.
    private func drainRenderLoop() {
        while true {
            os_unfair_lock_lock(&frameLock)
            if isBackgroundedLocked || latestPixelBuffer == nil || renderedFrameSerial == latestFrameSerial {
                renderScheduled = false
                os_unfair_lock_unlock(&frameLock)
                return
            }
            let pb = latestPixelBuffer!
            let prevPb = latestIsInterpolated ? latestPrevPixelBuffer : nil
            let serial = latestFrameSerial
            let mode = aspectModeLocked
            let sharpen = sharpeningLevelLocked.intensity
            let hdrMode = hdrToneModeLocked
            let debandStrength: Float = debandingEnabledLocked ? 1.0 : 0.0
            let metalFXEnabled = metalFXEnabledLocked
            let shadowLift = shadowLiftLocked
            let brightness = brightnessLocked
            let contrast = contrastLocked
            let saturation = saturationLocked
            let thermalMult = thermalEDRMultiplierLocked
            let edrHeadroom = currentEDRHeadroomLocked
            let interpPhase = latestInterpPhaseLocked
            let presentAt = pendingPresentTime
            renderedFrameSerial = serial
            os_unfair_lock_unlock(&frameLock)

            renderPixelBufferLocked(
                pb,
                previousPixelBuffer: prevPb,
                aspectMode: mode,
                sharpenStrength: sharpen,
                hdrToneMode: hdrMode,
                debandStrength: debandStrength,
                metalFXEnabled: metalFXEnabled,
                shadowLift: shadowLift,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                thermalEDRMultiplier: thermalMult,
                edrHeadroom: edrHeadroom,
                interpPhase: interpPhase,
                presentAt: presentAt
            )
        }
    }

    private func recreateDecompressionSessionLocked(formatDescription: CMVideoFormatDescription) {
        invalidateSessionLocked()

        let destinationAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            Self.logger.error("video VTDecompressionSessionCreate failed status=\(status, privacy: .public)")
            return
        }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        decompressionSession = session
        submittedFrameCount = 0
        decodedFrameCount = 0
    }

    private func invalidateSessionLocked() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    // MARK: - Zero-Copy Metal Rendering (`renderQueue` only)

    private func setupMetalLocked(layer: CAMetalLayer) {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice() else {
            Self.logger.error("video metal device unavailable")
            return
        }
        metalDevice = device
        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if cacheStatus == kCVReturnSuccess {
            textureCache = cache
        } else {
            Self.logger.error("video CVMetalTextureCacheCreate failed status=\(cacheStatus, privacy: .public)")
        }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct RenderUniforms {
            float2 scale;
            float isFullRange;
            float isBT709;
            float2 texelSize;
            float sharpenStrength;
            float hdrMode;
            float edrHeadroom;
            float hdrMaxPeak;
            float hdrContrast;
            float hdrSaturation;
            float hdrKnee;
            float debandStrength;
            float pad1;
            float pad2;
            float shadowLift;
            float brightness;
            float contrast;
            float saturation;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut videoVertex(uint vid [[vertex_id]],
                                     constant RenderUniforms &u [[buffer(0)]]) {
            const float2 positions[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            const float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };
            VertexOut out;
            out.position = float4(positions[vid] * u.scale, 0.0, 1.0);
            out.texCoord = uvs[vid];
            return out;
        }

        static inline float3 decodeYUV(float yRaw, float2 uvRaw, constant RenderUniforms &u) {
            float y;
            float2 cbcr;
            if (u.isFullRange > 0.5) {
                y = yRaw;
                cbcr = uvRaw - 0.5;
            } else {
                y = (yRaw - 16.0 / 255.0) * (255.0 / 219.0);
                cbcr = (uvRaw - 128.0 / 255.0) * (255.0 / 224.0);
            }
            float3 rgb;
            if (u.isBT709 > 0.5) {
                rgb.r = y + 1.5748 * cbcr.y;
                rgb.g = y - 0.187324 * cbcr.x - 0.468124 * cbcr.y;
                rgb.b = y + 1.8556 * cbcr.x;
            } else {
                rgb.r = y + 1.402 * cbcr.y;
                rgb.g = y - 0.344136 * cbcr.x - 0.714136 * cbcr.y;
                rgb.b = y + 1.772 * cbcr.x;
            }
            return saturate(rgb);
        }

        static inline float sampleSharpenedLuma(texture2d<float> lumaTex, float2 uv, constant RenderUniforms &u) {
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float c = lumaTex.sample(s, uv).r;
            if (u.sharpenStrength <= 0.01) {
                return c;
            }
            float t = lumaTex.sample(s, uv + float2(0.0, -u.texelSize.y)).r;
            float b = lumaTex.sample(s, uv + float2(0.0,  u.texelSize.y)).r;
            float l = lumaTex.sample(s, uv + float2(-u.texelSize.x, 0.0)).r;
            float r = lumaTex.sample(s, uv + float2( u.texelSize.x, 0.0)).r;
            // AMD FidelityFX CAS contrast-adaptive luma sharpening (zero chroma fringing, zero HUD ringing)
            float mn = min(c, min(min(t, b), min(l, r)));
            float mx = max(c, max(max(t, b), max(l, r)));
            float amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, 1e-4), 0.0, 1.0));
            float peak = mix(-0.125, -0.20, u.sharpenStrength);
            float w = amp * peak * u.sharpenStrength;
            return clamp((c + w * (t + b + l + r)) / (1.0 + 4.0 * w), 0.0, 1.0);
        }

        // Interleaved Gradient Noise (IGN) for artifact-free 8-bit dark-scene debanding & dithering
        static inline float ignNoise(float2 pixCoord) {
            return fract(52.9829189 * fract(dot(pixCoord, float2(0.06711056, 0.00583715))));
        }

        // Thresholded 4-tap rotated ring debanding: smooths 8-bit H.264 banding in dark sky/fog/shadows
        // while leaving real textures, foliage, and crisp UI text 100% untouched.
        static inline float sampleDebandedLuma(texture2d<float> lumaTex, float2 uv, constant RenderUniforms &u, float baseY) {
            if (u.debandStrength < 0.01) {
                return baseY;
            }
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float2 pix = uv / max(u.texelSize, float2(1e-5));
            float h = ignNoise(pix);
            float angle = h * 6.2831853;
            float radius = mix(5.0, 12.0, ignNoise(pix + float2(17.3, 31.7)));
            float2 dir1 = float2(cos(angle), sin(angle)) * radius * u.texelSize;
            float2 dir2 = float2(-dir1.y, dir1.x);

            float y1 = lumaTex.sample(s, uv + dir1).r;
            float y2 = lumaTex.sample(s, uv - dir1).r;
            float y3 = lumaTex.sample(s, uv + dir2).r;
            float y4 = lumaTex.sample(s, uv - dir2).r;

            float maxDiff = max(max(abs(y1 - baseY), abs(y2 - baseY)), max(abs(y3 - baseY), abs(y4 - baseY)));
            // Threshold ~7/255: only flat/gradient 8-bit bands qualify; textures & HUD fail immediately
            float bandWeight = (1.0 - smoothstep(0.014, 0.030, maxDiff)) * u.debandStrength;
            float avg = 0.25 * (y1 + y2 + y3 + y4);
            float dither = (h - 0.5) * (1.0 / 255.0) * bandWeight;
            return clamp(mix(baseY, avg, bandWeight * 0.72) + dither, 0.0, 1.0);
        }

        static inline float3 srgbToLinear(float3 c) {
            float3 safeC = max(c, float3(0.0));
            return select(pow((safeC + 0.055) / 1.055, float3(2.4)), safeC / 12.92, safeC <= float3(0.04045));
        }

        static inline float3 applyColorGrade(float3 srgb, constant RenderUniforms &u) {
            float3 c = srgb;
            if (u.shadowLift > 0.001) {
                float3 inv = 1.0 - c;
                c = saturate(c + u.shadowLift * inv * inv * inv * 1.15);
            }
            if (abs(u.brightness) > 0.001 || abs(u.contrast - 1.0) > 0.001) {
                c = saturate((c - 0.5) * u.contrast + 0.5 + u.brightness);
            }
            if (abs(u.saturation - 1.0) > 0.001) {
                float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
                c = saturate(mix(float3(luma), c, u.saturation));
            }
            return c;
        }

        static inline float3 applyAutoHDR(float3 srgb, constant RenderUniforms &u) {
            float3 lin = srgbToLinear(srgb);
            if (u.hdrMode < 0.5) {
                return lin;
            }
            float peak = clamp(min(u.edrHeadroom, u.hdrMaxPeak), 1.0, 4.0);
            bool hasHardwareEDR = (peak > 1.04);

            // 1. Contrast shaping: hardware EDR uses subtle shadow depth; SDR displays get stronger filmic punch
            float effectiveContrast = hasHardwareEDR ? u.hdrContrast : (1.0 + (u.hdrContrast - 1.0) * 1.95);
            lin = pow(max(lin, float3(0.0)), float3(effectiveContrast));

            // 2. Luminance-preserving color vibrancy
            float effectiveSat = hasHardwareEDR ? u.hdrSaturation : (1.0 + (u.hdrSaturation - 1.0) * 1.35);
            float luma = dot(lin, float3(0.2126, 0.7152, 0.0722));
            lin = max(mix(float3(luma), lin, effectiveSat), float3(hasHardwareEDR ? -0.25 : 0.0));
            luma = max(dot(lin, float3(0.2126, 0.7152, 0.0722)), 1e-5);

            // 3. Highlight expansion:
            //    - Hardware EDR/XDR/OLED display (>1.04x): expand highlights into true >1.0 peak nits!
            //    - SDR display (1.0x, e.g. Mac external monitor with system HDR off): perceptual filmic
            //      highlight lift + bright specular pop so Natural / Vivid / Cinema remain clearly distinct!
            float knee = u.hdrKnee;
            if (hasHardwareEDR) {
                if (luma > knee) {
                    float t = clamp((luma - knee) / max(1.0 - knee, 0.05), 0.0, 1.0);
                    float smoothT = t * t * (3.0 - 2.0 * t);
                    float targetLuma = mix(luma, peak, smoothT);
                    lin *= (targetLuma / luma);
                }
            } else {
                // Filmic perceptual HDR curve within SDR [0..1] range (lifted highlights + richer micro-contrast)
                float boost = clamp((u.hdrMaxPeak - 1.0) * 0.14, 0.08, 0.30);
                float shoulder = luma * (1.0 + boost) / (1.0 + boost * luma);
                lin = clamp(lin * (shoulder / luma), float3(0.0), float3(1.0));
            }
            return lin;
        }

        fragment float4 videoFragment(VertexOut in [[stage_in]],
                                      texture2d<float> lumaTex [[texture(0)]],
                                      texture2d<float> chromaTex [[texture(1)]],
                                      constant RenderUniforms &u [[buffer(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float2 uv = in.texCoord;
            float ySharp = sampleSharpenedLuma(lumaTex, uv, u);
            float yClean = sampleDebandedLuma(lumaTex, uv, u, ySharp);
            float3 rgb = decodeYUV(yClean, chromaTex.sample(s, uv).rg, u);
            rgb = applyColorGrade(rgb, u);
            return float4(applyAutoHDR(rgb, u), 1.0);
        }

        fragment float4 videoFragmentInterpolated(VertexOut in [[stage_in]],
                                                  texture2d<float> currY [[texture(0)]],
                                                  texture2d<float> currUV [[texture(1)]],
                                                  texture2d<float> prevY [[texture(2)]],
                                                  texture2d<float> prevUV [[texture(3)]],
                                                  texture2d<float> flowTex [[texture(4)]],
                                                  constant RenderUniforms &u [[buffer(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float2 uv = in.texCoord;
            float4 mvData = flowTex.sample(s, uv);
            float2 mv = mvData.xy;
            float conf = mvData.z;

            // Static HUD / crosshair / text protection: zero motion where luma is unchanged
            float rawPrevY = prevY.sample(s, uv).r;
            float rawCurrY = currY.sample(s, uv).r;
            float staticMask = smoothstep(0.010, 0.032, abs(rawCurrY - rawPrevY));
            mv *= staticMask;

            // Bidirectional fractional-phase warp (0.5 on 120Hz, time-aligned phase on 75Hz/100Hz displays)
            float phase = clamp(u.pad1, 0.15, 0.85);
            float2 uvPrev = clamp(uv - phase * mv, float2(0.0), float2(1.0));
            float2 uvCurr = clamp(uv + (1.0 - phase) * mv, float2(0.0), float2(1.0));
            float yPrev = sampleDebandedLuma(prevY, uvPrev, u, sampleSharpenedLuma(prevY, uvPrev, u));
            float yCurr = sampleDebandedLuma(currY, uvCurr, u, sampleSharpenedLuma(currY, uvCurr, u));
            float yExact = sampleDebandedLuma(currY, uv, u, sampleSharpenedLuma(currY, uv, u));
            float3 rgbPrev = decodeYUV(yPrev, prevUV.sample(s, uvPrev).rg, u);
            float3 rgbCurr = decodeYUV(yCurr, currUV.sample(s, uvCurr).rg, u);
            float3 rgbExactCurr = decodeYUV(yExact, currUV.sample(s, uv).rg, u);

            // Photometric consistency / occlusion & scene-cut guard
            float warpDiff = length(rgbPrev - rgbCurr);
            float consistency = 1.0 - smoothstep(0.14, 0.42, warpDiff);
            float blendW = conf * consistency;
            float3 blended = mix(rgbPrev, rgbCurr, phase);
            float3 srgbOut = applyColorGrade(mix(rgbExactCurr, blended, blendW), u);
            return float4(applyAutoHDR(srgbOut, u), 1.0);
        }

        fragment float4 blitFragment(VertexOut in [[stage_in]],
                                     texture2d<float> srcTex [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            return srcTex.sample(s, in.texCoord);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "videoVertex")
            desc.fragmentFunction = library.makeFunction(name: "videoFragment")
            desc.colorAttachments[0].pixelFormat = layer.pixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)

            let interpDesc = MTLRenderPipelineDescriptor()
            interpDesc.vertexFunction = library.makeFunction(name: "videoVertex")
            interpDesc.fragmentFunction = library.makeFunction(name: "videoFragmentInterpolated")
            interpDesc.colorAttachments[0].pixelFormat = layer.pixelFormat
            interpPipelineState = try device.makeRenderPipelineState(descriptor: interpDesc)

            let blitDesc = MTLRenderPipelineDescriptor()
            blitDesc.vertexFunction = library.makeFunction(name: "videoVertex")
            blitDesc.fragmentFunction = library.makeFunction(name: "blitFragment")
            blitDesc.colorAttachments[0].pixelFormat = layer.pixelFormat
            blitPipelineState = try device.makeRenderPipelineState(descriptor: blitDesc)

            opticalFlowEngine = MetalOpticalFlowEngine(device: device)
            Self.logger.info("video metal zero-copy pipeline ready (nv12 + deband + metalfx + 120fps bidirectional optical-flow)")
        } catch {
            Self.logger.error("video metal pipeline error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureMetalFXLocked(
        device: MTLDevice,
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        isHDR: Bool
    ) -> (MTLFXSpatialScaler, MTLTexture, MTLTexture)? {
        let sig = (inputWidth, inputHeight, outputWidth, outputHeight, isHDR)
        if sig == metalFXSig,
           let scaler = metalFXScaler,
           let inTex = metalFXInputTex,
           let outTex = metalFXOutputTex {
            return (scaler, inTex, outTex)
        }

        let inDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: inputWidth,
            height: inputHeight,
            mipmapped: false
        )
        inDesc.usage = [.renderTarget, .shaderRead]
        inDesc.storageMode = .private

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite, .shaderRead]
        outDesc.storageMode = .private

        let fxDesc = MTLFXSpatialScalerDescriptor()
        fxDesc.inputWidth = inputWidth
        fxDesc.inputHeight = inputHeight
        fxDesc.outputWidth = outputWidth
        fxDesc.outputHeight = outputHeight
        fxDesc.colorTextureFormat = .rgba16Float
        fxDesc.outputTextureFormat = .rgba16Float
        fxDesc.colorProcessingMode = isHDR ? .hdr : .linear

        guard let inTex = device.makeTexture(descriptor: inDesc),
              let outTex = device.makeTexture(descriptor: outDesc),
              let scaler = fxDesc.makeSpatialScaler(device: device) else {
            metalFXScaler = nil
            metalFXInputTex = nil
            metalFXOutputTex = nil
            metalFXSig = (0, 0, 0, 0, false)
            return nil
        }

        metalFXScaler = scaler
        metalFXInputTex = inTex
        metalFXOutputTex = outTex
        metalFXSig = sig
        Self.logger.info(
            "metalfx spatial scaler ready \(inputWidth, privacy: .public)x\(inputHeight, privacy: .public) -> \(outputWidth, privacy: .public)x\(outputHeight, privacy: .public) hdr=\(isHDR, privacy: .public)"
        )
        return (scaler, inTex, outTex)
    }

    private func renderPixelBufferLocked(
        _ pixelBuffer: CVPixelBuffer,
        previousPixelBuffer: CVPixelBuffer?,
        aspectMode: VideoAspectMode,
        sharpenStrength: Float,
        hdrToneMode: VideoHDRToneMode,
        debandStrength: Float,
        metalFXEnabled: Bool,
        shadowLift: Float,
        brightness: Float,
        contrast: Float,
        saturation: Float,
        thermalEDRMultiplier: Float,
        edrHeadroom: Float,
        interpPhase: Float,
        presentAt: CFTimeInterval
    ) {
        guard !isBackgrounded(),
              let layer = metalLayer,
              let device = metalDevice,
              let commandQueue,
              let pipelineState,
              let textureCache else {
            return
        }

        let drawableSize = layer.drawableSize
        guard drawableSize.width >= 2, drawableSize.height >= 2 else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let pixelFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)

        autoreleasepool {
            var yTexRef: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,
                &yTexRef
            )
            var uvTexRef: CVMetalTexture?
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .rg8Unorm,
                width / 2,
                height / 2,
                1,
                &uvTexRef
            )
            guard yStatus == kCVReturnSuccess,
                  uvStatus == kCVReturnSuccess,
                  let yTex = yTexRef.flatMap({ CVMetalTextureGetTexture($0) }),
                  let uvTex = uvTexRef.flatMap({ CVMetalTextureGetTexture($0) }) else {
                return
            }

            var prevYTexRef: CVMetalTexture?
            var prevUVTexRef: CVMetalTexture?
            var prevYTex: MTLTexture?
            var prevUVTex: MTLTexture?
            if let prevPB = previousPixelBuffer,
               CVPixelBufferGetWidth(prevPB) == width,
               CVPixelBufferGetHeight(prevPB) == height {
                let pyStatus = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, prevPB, nil, .r8Unorm, width, height, 0, &prevYTexRef
                )
                let puvStatus = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, prevPB, nil, .rg8Unorm, width / 2, height / 2, 1, &prevUVTexRef
                )
                if pyStatus == kCVReturnSuccess, puvStatus == kCVReturnSuccess {
                    prevYTex = prevYTexRef.flatMap { CVMetalTextureGetTexture($0) }
                    prevUVTex = prevUVTexRef.flatMap { CVMetalTextureGetTexture($0) }
                }
            }

            guard let drawable = layer.nextDrawable(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            // Encode sub-millisecond bidirectional pyramid optical flow in the exact same GPU command buffer
            var flowTex: MTLTexture?
            if let prevYTex, let flowEngine = opticalFlowEngine, flowEngine.isReady {
                flowTex = flowEngine.encodeOpticalFlow(
                    commandBuffer: commandBuffer,
                    prevY: prevYTex,
                    currY: yTex
                )
            }

            let viewAspect = Float(drawableSize.width / drawableSize.height)
            let videoAspect = Float(width) / Float(height)
            var scaleX: Float = 1.0
            var scaleY: Float = 1.0

            switch aspectMode {
            case .stretch:
                scaleX = 1.0
                scaleY = 1.0
            case .fit:
                if videoAspect > viewAspect {
                    scaleY = viewAspect / videoAspect
                } else {
                    scaleX = videoAspect / viewAspect
                }
            case .fill:
                if videoAspect > viewAspect {
                    scaleX = videoAspect / viewAspect
                } else {
                    scaleY = viewAspect / videoAspect
                }
            }

            let isFullRange: Float = (pixelFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 1.0 : 0.0
            let isBT601: Bool = {
                guard let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else {
                    return false
                }
                return matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
            }()
            let (hdrActive, rawHdrMaxPeak, hdrContrast, hdrSaturation, hdrKnee): (Float, Float, Float, Float, Float) = {
                switch hdrToneMode {
                case .off:
                    return (0.0, 1.0, 1.0, 1.0, 1.0)
                case .natural:
                    return (1.0, 1.85, 1.06, 1.10, 0.65)
                case .vivid:
                    return (1.0, 2.50, 1.11, 1.20, 0.58)
                case .cinema:
                    return (1.0, 3.20, 1.16, 1.15, 0.55)
                }
            }()
            // Thermal protection gently reduces peak EDR headroom when iPad reports `.serious`/`.critical`
            let hdrMaxPeak = hdrActive > 0.5
                ? max(1.0, 1.0 + (rawHdrMaxPeak - 1.0) * thermalEDRMultiplier)
                : 1.0

            // Decide whether Apple MetalFX Spatial Upscaling should run (only when upscaling strictly > 1x)
            let desiredW = min(max(Int(round(Float(drawableSize.width) * min(scaleX, 1.0))), 1), width * 2)
            let desiredH = min(max(Int(round(Float(drawableSize.height) * min(scaleY, 1.0))), 1), height * 2)
            let wantsMetalFX = metalFXEnabled
                && blitPipelineState != nil
                && MTLFXSpatialScalerDescriptor.supportsDevice(device)
                && (desiredW > width + 16 || desiredH > height + 16)
                && desiredW >= width && desiredH >= height
                && desiredW <= 4096 && desiredH <= 4096

            let fxBundle = wantsMetalFX
                ? ensureMetalFXLocked(
                    device: device,
                    inputWidth: width,
                    inputHeight: height,
                    outputWidth: desiredW,
                    outputHeight: desiredH,
                    isHDR: hdrActive > 0.5
                )
                : nil

            var uniforms = RenderUniforms(
                scaleX: fxBundle != nil ? 1.0 : scaleX,
                scaleY: fxBundle != nil ? 1.0 : scaleY,
                isFullRange: isFullRange,
                isBT709: isBT601 ? 0.0 : 1.0,
                texelSizeX: 1.0 / Float(max(width, 1)),
                texelSizeY: 1.0 / Float(max(height, 1)),
                sharpenStrength: sharpenStrength,
                hdrMode: hdrActive,
                edrHeadroom: edrHeadroom,
                hdrMaxPeak: hdrMaxPeak,
                hdrContrast: hdrContrast,
                hdrSaturation: hdrSaturation,
                hdrKnee: hdrKnee,
                debandStrength: debandStrength,
                pad1: interpPhase,
                pad2: 0.0,
                shadowLift: shadowLift,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation
            )

            // Pass 1: Decode NV12 + CAS + Deband + (120Hz Optical Flow) + Auto-HDR
            let pass1Desc = MTLRenderPassDescriptor()
            pass1Desc.colorAttachments[0].texture = fxBundle?.1 ?? drawable.texture
            pass1Desc.colorAttachments[0].loadAction = .clear
            pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass1Desc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) else {
                return
            }

            if let flowTex, let prevYTex, let prevUVTex, let interpPipelineState {
                encoder.setRenderPipelineState(interpPipelineState)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
                encoder.setFragmentTexture(yTex, index: 0)
                encoder.setFragmentTexture(uvTex, index: 1)
                encoder.setFragmentTexture(prevYTex, index: 2)
                encoder.setFragmentTexture(prevUVTex, index: 3)
                encoder.setFragmentTexture(flowTex, index: 4)

                interpRenderedCount &+= 1
                if interpRenderedCount == 1 || interpRenderedCount % 600 == 0 {
                    Self.logger.info(
                        "video 120fps metal optical-flow active #\(self.interpRenderedCount, privacy: .public) \(width, privacy: .public)x\(height, privacy: .public)"
                    )
                }
            } else {
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
                encoder.setFragmentTexture(yTex, index: 0)
                encoder.setFragmentTexture(uvTex, index: 1)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            // Pass 2 & 3 (optional): Apple MetalFX Spatial Upscaling -> Aspect-mapped Drawable Blit
            var didRunMetalFX = false
            if let (scaler, inTex, outTex) = fxBundle, let blitPipelineState {
                scaler.colorTexture = inTex
                scaler.outputTexture = outTex
                scaler.encode(commandBuffer: commandBuffer)

                let blitPassDesc = MTLRenderPassDescriptor()
                blitPassDesc.colorAttachments[0].texture = drawable.texture
                blitPassDesc.colorAttachments[0].loadAction = .clear
                blitPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                blitPassDesc.colorAttachments[0].storeAction = .store

                if let blitEnc = commandBuffer.makeRenderCommandEncoder(descriptor: blitPassDesc) {
                    var blitUniforms = uniforms
                    blitUniforms.scaleX = scaleX
                    blitUniforms.scaleY = scaleY
                    blitEnc.setRenderPipelineState(blitPipelineState)
                    blitEnc.setVertexBytes(&blitUniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
                    blitEnc.setFragmentTexture(outTex, index: 0)
                    blitEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    blitEnc.endEncoding()
                    didRunMetalFX = true
                }
            }

            let now = CACurrentMediaTime()
            if presentAt > now && (presentAt - now) < 0.045 {
                commandBuffer.present(drawable, atTime: presentAt)
            } else {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()

            // Measure real presented display FPS (shows true 120 when optical-flow 120Hz is active)
            os_unfair_lock_lock(&frameLock)
            isMetalFXActiveLocked = didRunMetalFX
            presentedFramesInWindow += 1
            if fpsWindowStartTime == 0 {
                fpsWindowStartTime = now
            } else if (now - fpsWindowStartTime) >= 1.0 {
                measuredDisplayFpsLocked = Double(presentedFramesInWindow) / (now - fpsWindowStartTime)
                presentedFramesInWindow = 0
                fpsWindowStartTime = now
            }
            os_unfair_lock_unlock(&frameLock)

            renderedCountForCacheFlush &+= 1
            if renderedCountForCacheFlush % 120 == 0 {
                CVMetalTextureCacheFlush(textureCache, 0)
            }
        }
    }

    // MARK: - Helpers

    private func requestKeyframeThrottled() {
        let now = CACurrentMediaTime()
        if now - lastKeyframeRequestTime >= 0.45 {
            lastKeyframeRequestTime = now
            onNeedKeyframe?()
        }
    }

    private func scanAnnexBNALRanges(in data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        result.reserveCapacity(8)
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = data.count
            var offset = 0
            var currentStart: Int?

            while offset < count {
                var startCodeLen = 0
                if offset + 3 < count &&
                    base[offset] == 0 && base[offset + 1] == 0 && base[offset + 2] == 0 && base[offset + 3] == 1 {
                    startCodeLen = 4
                } else if offset + 2 < count &&
                    base[offset] == 0 && base[offset + 1] == 0 && base[offset + 2] == 1 {
                    startCodeLen = 3
                }

                if startCodeLen > 0 {
                    if let start = currentStart, offset > start {
                        result.append(start..<offset)
                    }
                    offset += startCodeLen
                    currentStart = offset
                } else {
                    offset += 1
                }
            }

            if let start = currentStart, count > start {
                result.append(start..<count)
            }
        }
        return result
    }

    private func createFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsBuf.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        return status == noErr ? formatDesc : nil
    }

    /// Single-pass direct AVCC packing straight into `CMBlockBuffer` backing memory (zero intermediate NAL/AVCC copies).
    private func createSampleBufferDirect(
        annexBData: Data,
        pictureRanges: [Range<Int>],
        formatDescription: CMVideoFormatDescription,
        ptsUs: Int64,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var length = 0
        for range in pictureRanges {
            length += 4 + range.count
        }
        guard length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = CMBlockBufferAssureBlockMemory(block)
        guard status == kCMBlockBufferNoErr else { return nil }

        var dstPtr: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dstPtr
        )
        guard status == kCMBlockBufferNoErr, let rawDst = dstPtr else { return nil }

        annexBData.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.baseAddress else { return }
            let dstBase = UnsafeMutableRawPointer(rawDst)
            var writeOffset = 0
            for range in pictureRanges {
                let nalLen = range.count
                var lengthBE = UInt32(nalLen).bigEndian
                withUnsafeBytes(of: &lengthBE) { lenBytes in
                    if let lb = lenBytes.baseAddress {
                        dstBase.advanced(by: writeOffset).copyMemory(from: lb, byteCount: 4)
                    }
                }
                writeOffset += 4
                dstBase.advanced(by: writeOffset).copyMemory(
                    from: srcBase.advanced(by: range.lowerBound),
                    byteCount: nalLen
                )
                writeOffset += nalLen
            }
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let buffer = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }

        return buffer
    }

    private struct UncheckedMetalLayerBox: @unchecked Sendable {
        let layer: CAMetalLayer
    }
}

// MARK: - UIKit / SwiftUI 120Hz ProMotion Metal Display View

private final class UncheckedPixelBufferBox: @unchecked Sendable {
    let pb: CVPixelBuffer
    init(pb: CVPixelBuffer) { self.pb = pb }
}

#if os(iOS)
final class VideoDisplayUIView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    var onDrawableSizeChanged: (() -> Void)?
    var onDisplayTick: ((CFTimeInterval, CFTimeInterval, Float) -> Void)?
    private var proMotionLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true

        metalLayer.device = MTLCreateSystemDefaultDevice()
        // 16-bit float extendedLinearSRGB enables native Apple XDR/OLED EDR HDR peak brightness
        // while staying 100% bit-exact SDR when `wantsExtendedDynamicRangeContent == false`.
        metalLayer.pixelFormat = .rgba16Float
        if let edrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            metalLayer.colorspace = edrSpace
        }
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        // CRITICAL: Must be 3 (default triple-buffered swapchain). Setting 2 causes
        // `nextDrawable()` to block for an entire 16.67ms VSync cycle on iPadOS WindowServer!
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    func setEDREnabled(_ enabled: Bool) {
        if metalLayer.wantsExtendedDynamicRangeContent != enabled {
            metalLayer.wantsExtendedDynamicRangeContent = enabled
        }
    }

    var liveEDRHeadroom: Float {
        Float(window?.screen.currentEDRHeadroom ?? UIScreen.main.currentEDRHeadroom)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        proMotionLink?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateDrawableSize()
            startProMotionLock()
        } else {
            stopProMotionLock()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let newSize = CGSize(
            width: max(floor(bounds.width * scale), 1),
            height: max(floor(bounds.height * scale), 1)
        )
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
            onDrawableSizeChanged?()
        }
    }

    /// Keep iPad Pro / iPhone Pro ProMotion (or external HDMI/USB-C display) locked to native VSync.
    private func startProMotionLock() {
        stopProMotionLock()
        let screen = window?.screen ?? UIScreen.main
        let maxHz = Float(max(screen.maximumFramesPerSecond, 60))
        let link = screen.displayLink(withTarget: self, selector: #selector(proMotionTick(_:)))
            ?? CADisplayLink(target: self, selector: #selector(proMotionTick(_:)))
        if maxHz >= 100 {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: maxHz, preferred: maxHz)
        } else {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxHz, preferred: maxHz)
        }
        link.add(to: .main, forMode: .common)
        proMotionLink = link
    }

    private func stopProMotionLock() {
        proMotionLink?.invalidate()
        proMotionLink = nil
    }

    @objc private func proMotionTick(_ link: CADisplayLink) {
        onDisplayTick?(link.timestamp, link.targetTimestamp, liveEDRHeadroom)
    }
}

struct VideoDecoderView: UIViewRepresentable {
    let renderer: H264StreamRenderer
    let aspectMode: VideoAspectMode
    let hdrToneMode: VideoHDRToneMode

    func makeUIView(context: Context) -> VideoDisplayUIView {
        let view = VideoDisplayUIView()
        view.setEDREnabled(hdrToneMode != .off)
        view.onDrawableSizeChanged = { [weak renderer] in
            renderer?.handleDrawableSizeChanged()
        }
        view.onDisplayTick = { [weak renderer] ts, targetTs, headroom in
            renderer?.updateEDRHeadroom(headroom)
            renderer?.handleDisplayTick(now: ts, targetTimestamp: targetTs)
        }
        renderer.updateHDRToneMode(hdrToneMode)
        renderer.attach(metalLayer: view.metalLayer, aspectMode: aspectMode)
        return view
    }

    func updateUIView(_ uiView: VideoDisplayUIView, context: Context) {
        uiView.setEDREnabled(hdrToneMode != .off)
        renderer.updateAspectMode(aspectMode)
        renderer.updateHDRToneMode(hdrToneMode)
    }

    static func dismantleUIView(_ uiView: VideoDisplayUIView, coordinator: ()) {
        uiView.onDrawableSizeChanged = nil
        uiView.onDisplayTick = nil
    }
}
#elseif os(macOS)
final class VideoDisplayNSView: NSView {
    let metalLayer = CAMetalLayer()

    var onDrawableSizeChanged: (() -> Void)?
    var onDisplayTick: ((CFTimeInterval, CFTimeInterval, Float) -> Void)?
    private var proMotionLink: CADisplayLink?
    private var screenChangeObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layerContentsRedrawPolicy = .duringViewResize

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .rgba16Float
        if let edrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            metalLayer.colorspace = edrSpace
        }
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor

        // Canonical AppKit layer-hosting order: assign `layer` BEFORE setting `wantsLayer = true`.
        self.layer = metalLayer
        self.wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopScreenObservers()
        proMotionLink?.invalidate()
    }

    func setEDREnabled(_ enabled: Bool) {
        if metalLayer.wantsExtendedDynamicRangeContent != enabled {
            metalLayer.wantsExtendedDynamicRangeContent = enabled
        }
    }

    var liveEDRHeadroom: Float {
        let screen = window?.screen ?? NSScreen.main
        return Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopScreenObservers()
        if let win = window {
            updateDrawableSize()
            startProMotionLock()
            let nc = NotificationCenter.default
            screenChangeObserver = nc.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.updateDrawableSize()
                self?.startProMotionLock()
            }
            screenParamsObserver = nc.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateDrawableSize()
                self?.startProMotionLock()
            }
        } else {
            stopProMotionLock()
        }
    }

    private func stopScreenObservers() {
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenChangeObserver = nil
        }
        if let obs = screenParamsObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParamsObserver = nil
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let newSize = CGSize(
            width: max(floor(bounds.width * scale), 1),
            height: max(floor(bounds.height * scale), 1)
        )
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
            onDrawableSizeChanged?()
        }
    }

    private func startProMotionLock() {
        stopProMotionLock()
        let screen = window?.screen ?? NSScreen.main
        let maxHz = Float(max(screen?.maximumFramesPerSecond ?? 60, 60))
        let link = self.displayLink(target: self, selector: #selector(proMotionTick(_:)))
        if maxHz >= 100 {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: maxHz, preferred: maxHz)
        } else {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxHz, preferred: maxHz)
        }
        link.add(to: .main, forMode: .common)
        proMotionLink = link
    }

    private func stopProMotionLock() {
        proMotionLink?.invalidate()
        proMotionLink = nil
    }

    @objc private func proMotionTick(_ link: CADisplayLink) {
        onDisplayTick?(link.timestamp, link.targetTimestamp, liveEDRHeadroom)
    }
}

struct VideoDecoderView: NSViewRepresentable {
    let renderer: H264StreamRenderer
    let aspectMode: VideoAspectMode
    let hdrToneMode: VideoHDRToneMode

    func makeNSView(context: Context) -> VideoDisplayNSView {
        let view = VideoDisplayNSView()
        view.setEDREnabled(hdrToneMode != .off)
        view.onDrawableSizeChanged = { [weak renderer] in
            renderer?.handleDrawableSizeChanged()
        }
        view.onDisplayTick = { [weak renderer] ts, targetTs, headroom in
            renderer?.updateEDRHeadroom(headroom)
            renderer?.handleDisplayTick(now: ts, targetTimestamp: targetTs)
        }
        renderer.updateHDRToneMode(hdrToneMode)
        renderer.attach(metalLayer: view.metalLayer, aspectMode: aspectMode)
        return view
    }

    func updateNSView(_ nsView: VideoDisplayNSView, context: Context) {
        nsView.setEDREnabled(hdrToneMode != .off)
        renderer.updateAspectMode(aspectMode)
        renderer.updateHDRToneMode(hdrToneMode)
    }

    static func dismantleNSView(_ nsView: VideoDisplayNSView, coordinator: ()) {
        nsView.onDrawableSizeChanged = nil
        nsView.onDisplayTick = nil
    }
}
#endif
