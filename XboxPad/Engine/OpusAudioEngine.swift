import AVFoundation
import AudioToolbox
import Foundation
import os
import QuartzCore

/// Low-latency native Apple AudioToolbox Opus decoder + AVAudioEngine adaptive jitter-smoothed
/// ring-buffer renderer. Uses Apple's built-in kAudioFormatOpus codec with zero external libopus.
final class OpusAudioEngine: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "audio")

    private let decodeQueue = DispatchQueue(label: "com.elliot.xboxpad.audio.decode", qos: .userInteractive)

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var converter: AudioConverterRef?
    private var outputSampleRate: Double = 48_000
    private let outputChannels: UInt32 = 2
    private var inputSampleRate: Double = 48_000
    private var inputChannels: UInt32 = 2
    private var isRunning = false
    private var isMuted = false

    // Real-time lock-guarded interleaved Float32 stereo ring buffer (500ms capacity @ 48kHz stereo)
    private var ringLock = os_unfair_lock_s()
    private var ringBuffer: [Float]
    private var ringCapacity: Int
    private var ringReadIndex: Int = 0
    private var ringWriteIndex: Int = 0
    private var ringCount: Int = 0
    private var isPriming: Bool = true
    private var fadeInRemainingFrames: Int = 0
    private var lastSampleL: Float = 0
    private var lastSampleR: Float = 0

    // Burst-gap-aware adaptive jitter cushion (in interleaved stereo float samples):
    // - Clean Wi-Fi/LAN (20ms Opus arrivals) -> stays ultra-tight at 32-38ms for crisp lip-sync
    // - Bursty wireless (Apple AWDL 45-55ms off-channel hops or 5G hotspot) -> proactively tracks
    //   inter-packet arrival gap peaks and expands cushion to ~75-95ms BEFORE underruns occur,
    //   absorbing the entire 48ms blackout with zero dropouts, then relaxes smoothly when clean.
    private var pacingMode: VideoFramePacingMode = .auto
    private var primingMs: Int = 32
    private var underrunBonusMs: Int = 0
    private var primingSamples: Int = 48_000 * 2 * 32 / 1000
    private var resumePrimingSamples: Int = 48_000 * 2 * 24 / 1000
    private var maxBufferedSamples: Int = 48_000 * 2 * 76 / 1000
    private var targetBufferedSamples: Int = 48_000 * 2 * 38 / 1000
    private var hasStartedPlayback: Bool = false
    private var underrunCount: UInt64 = 0
    private var lastUnderrunTime: CFTimeInterval = 0
    private var lastRelaxCheckTime: CFTimeInterval = 0
    private var lastPacketArrivalTime: CFTimeInterval = 0
    private var smoothedPeakGapMs: Double = 20.0
    private var lastLoggedTargetMs: Int = 32
    private var consecutiveMissingCallbacks: Int = 0

    // Pre-allocated reusable decode buffers on `decodeQueue` (zero per-packet heap allocations)
    private var decodeScratchPCM: [Float] = Array(repeating: 0, count: 5760 * 2)
    private let reusableInputBox = ReusableOpusInputBox()
    private var pcmTap: (@Sendable ([Float], Int, Double, Int) -> Void)?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    init() {
        let cap = 48_000 * 2 * 500 / 1000
        self.ringCapacity = cap
        self.ringBuffer = Array(repeating: 0, count: cap)
    }

    deinit {
        stop()
    }

    var bufferedDurationMs: Double {
        os_unfair_lock_lock(&ringLock)
        let samples = ringCount
        os_unfair_lock_unlock(&ringLock)
        let denom = max(outputSampleRate * Double(outputChannels), 1.0)
        return (Double(samples) / denom) * 1000.0
    }

    func setMuted(_ muted: Bool) {
        decodeQueue.async { [weak self] in
            self?.isMuted = muted
            if muted {
                self?.clearRingBuffer()
            }
        }
    }

    func setPacingMode(_ mode: VideoFramePacingMode) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.ringLock)
            self.pacingMode = mode
            self.recomputeWatermarksLocked(sampleRate: self.outputSampleRate, channels: Int(self.outputChannels))
            os_unfair_lock_unlock(&self.ringLock)
        }
    }

    func setPCMTap(_ tap: (@Sendable ([Float], Int, Double, Int) -> Void)?) {
        decodeQueue.async { [weak self] in
            self?.pcmTap = tap
        }
    }

    func start(sampleRate: Double = 48_000, channels: UInt32 = 2) {
        decodeQueue.async { [weak self] in
            self?.startLocked(sampleRate: sampleRate, inputChannels: max(channels, 1))
        }
    }

    /// Lightweight foreground/route recovery: restarts AVAudioEngine ONLY if stopped,
    /// avoiding a full tear-down/recreate glitch when audio is already healthy.
    func ensureRunning(sampleRate: Double = 48_000, channels: UInt32 = 2) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if self.isRunning, let engine = self.audioEngine {
                if !engine.isRunning {
                    self.configureAudioSession(sampleRate: self.outputSampleRate)
                    do {
                        try engine.start()
                        Self.logger.info("audio engine resumed without rebuild")
                    } catch {
                        self.startLocked(sampleRate: sampleRate, inputChannels: max(channels, 1))
                    }
                }
            } else {
                self.startLocked(sampleRate: sampleRate, inputChannels: max(channels, 1))
            }
        }
    }

    func stop() {
        decodeQueue.sync {
            stopLocked()
        }
    }

    func enqueueOpusFrame(data: Data, sampleRate: UInt32, channels: UInt16) {
        guard !data.isEmpty else { return }
        decodeQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isMuted else { return }
            let sr = sampleRate > 0 ? Double(sampleRate) : 48_000
            let ch = channels > 0 ? UInt32(channels) : 2
            if self.converter == nil || sr != self.inputSampleRate || ch != self.inputChannels {
                self.recreateConverter(inputSampleRate: sr, inputChannels: ch)
            }
            self.decodeAndBuffer(opusPacket: data)
        }
    }

    // MARK: - Setup & Teardown

    private func startLocked(sampleRate: Double, inputChannels: UInt32) {
        stopLocked()

        let sr = sampleRate > 0 ? sampleRate : 48_000
        outputSampleRate = sr
        self.inputSampleRate = sr
        self.inputChannels = inputChannels

        let chCount = Int(outputChannels)
        let cap = Int(sr) * chCount * 500 / 1000
        os_unfair_lock_lock(&ringLock)
        ringCapacity = max(cap, 16_384)
        ringBuffer = Array(repeating: 0, count: ringCapacity)
        ringReadIndex = 0
        ringWriteIndex = 0
        ringCount = 0
        isPriming = true
        hasStartedPlayback = false
        fadeInRemainingFrames = 0
        lastSampleL = 0
        lastSampleR = 0
        underrunCount = 0
        underrunBonusMs = 0
        lastUnderrunTime = 0
        lastRelaxCheckTime = CACurrentMediaTime()
        lastPacketArrivalTime = 0
        smoothedPeakGapMs = 20.0
        lastLoggedTargetMs = 32
        consecutiveMissingCallbacks = 0
        recomputeWatermarksLocked(sampleRate: sr, channels: chCount)
        os_unfair_lock_unlock(&ringLock)

        configureAudioSession(sampleRate: sr)
        recreateConverter(inputSampleRate: sr, inputChannels: inputChannels)

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sr,
            channels: AVAudioChannelCount(outputChannels),
            interleaved: false
        ) else { return }

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            self.readFromRing(frames: frames, channels: chCount, output: abl)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
            audioEngine = engine
            sourceNode = node
            isRunning = true
            observeAudioSessionNotifications(engine: engine)
        } catch {
            Self.logger.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            isRunning = false
        }
    }

    private func recomputeWatermarksLocked(sampleRate: Double, channels: Int) {
        let samplesPerMs = max(Int(sampleRate) * channels / 1000, 2)
        let burstExcessMs = max(0, Int(ceil(smoothedPeakGapMs - 20.0)))
        let targetMs: Int
        let headroomMs: Int
        switch pacingMode {
        case .immediate:
            targetMs = min(24 + underrunBonusMs, 56)
            headroomMs = 30
        case .smooth:
            targetMs = min(max(48, 28 + burstExcessMs + 10 + underrunBonusMs), 92)
            headroomMs = max(42, burstExcessMs + 16)
        case .auto:
            // Tight continuous ramp: ~26-34ms on clean LAN, expanding smoothly up to ~84ms only under real AWDL bursts
            let extra = burstExcessMs > 2 ? (burstExcessMs + min(burstExcessMs / 2, 8)) : 0
            targetMs = min(26 + extra + underrunBonusMs, 86)
            headroomMs = max(36, burstExcessMs + 16)
        }
        primingMs = targetMs
        primingSamples = samplesPerMs * targetMs
        resumePrimingSamples = samplesPerMs * min(max(20, burstExcessMs / 2 + 12), 40)
        targetBufferedSamples = samplesPerMs * (targetMs + 4)
        maxBufferedSamples = samplesPerMs * min(targetMs + headroomMs, 150)
    }

    private func stopLocked() {
        isRunning = false
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        sourceNode = nil
        audioEngine = nil
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
        clearRingBuffer()
    }

    private func configureAudioSession(sampleRate: Double) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // NOTE: Do NOT pass `.allowBluetoothA2DP` with `.playback` — Apple rejects it with paramErr (-50).
        // `.playback` automatically routes to Bluetooth A2DP headphones & AirPods.
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            try? session.setCategory(.playback)
        }
        try? session.setPreferredSampleRate(sampleRate)
        // 10ms hardware I/O buffer balances snappy sync with zero real-time callback jitter on iOS/iPadOS
        try? session.setPreferredIOBufferDuration(0.010)
        try? session.setActive(true)
        #endif
    }

    private func observeAudioSessionNotifications(engine: AVAudioEngine) {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            if type == .ended {
                self.ensureRunning(sampleRate: self.outputSampleRate, channels: self.inputChannels)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.ensureRunning(sampleRate: self.outputSampleRate, channels: self.inputChannels)
        }
        #endif

        // Handles AirPods / Bluetooth / USB-C DAC hot-swaps where AVAudioEngine halts its graph.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.decodeQueue.async {
                guard self.isRunning else { return }
                Self.logger.info("audio engine configuration changed -> rebuilding smoothly")
                self.startLocked(sampleRate: self.outputSampleRate, inputChannels: self.inputChannels)
            }
        }
    }

    private func recreateConverter(inputSampleRate: Double, inputChannels: UInt32) {
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
        self.inputSampleRate = inputSampleRate
        self.inputChannels = max(inputChannels, 1)

        var inDesc = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: self.inputChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * outputChannels
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: outputChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &newConverter)
        if status == noErr {
            converter = newConverter
        }
    }

    // MARK: - Opus Decoding (Zero Per-Packet Heap Allocations)

    /// Custom sentinel status per Apple QA1317 ("temporary end of input, NOT EOF"):
    /// returning `noErr` with 0 packets permanently latches CoreAudio's Opus converter into EOF!
    private static let noMoreInputStatus: OSStatus = 0x6E6F_696E // 'noin'

    private final class ReusableOpusInputBox {
        private var capacity: Int = 2048
        var storage: UnsafeMutableRawPointer
        var byteCount: Int = 0
        var channels: UInt32 = 2
        let packetDescPtr: UnsafeMutablePointer<AudioStreamPacketDescription>
        var consumed = false

        init() {
            storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            packetDescPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            packetDescPtr.initialize(to: AudioStreamPacketDescription())
        }

        deinit {
            packetDescPtr.deinitialize(count: 1)
            packetDescPtr.deallocate()
            storage.deallocate()
        }

        func prepare(data: Data, channels: UInt32) {
            let count = data.count
            if count > capacity {
                storage.deallocate()
                capacity = max(count, capacity * 2)
                storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            }
            data.withUnsafeBytes { raw in
                if let src = raw.baseAddress, count > 0 {
                    storage.copyMemory(from: src, byteCount: count)
                }
            }
            packetDescPtr.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(count)
            )
            self.byteCount = count
            self.channels = max(channels, 1)
            self.consumed = false
        }
    }

    private func decodeAndBuffer(opusPacket: Data) {
        guard let converter else { return }

        let expectedFrames = Self.estimateOpusFrameCount(packet: opusPacket, sampleRate: Int(outputSampleRate))
        let channels = Int(outputChannels)
        let neededFloats = expectedFrames * channels
        if decodeScratchPCM.count < neededFloats {
            decodeScratchPCM = Array(repeating: 0, count: neededFloats)
        }

        reusableInputBox.prepare(data: opusPacket, channels: inputChannels)
        var ioOutputFrames = UInt32(expectedFrames)

        let status: OSStatus = withExtendedLifetime(reusableInputBox) {
            decodeScratchPCM.withUnsafeMutableBytes { outRaw in
                var outBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: outputChannels,
                        mDataByteSize: UInt32(neededFloats * MemoryLayout<Float>.size),
                        mData: outRaw.baseAddress
                    )
                )

                let userData = Unmanaged.passUnretained(reusableInputBox).toOpaque()
                return AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData -> OSStatus in
                        guard let inUserData else {
                            ioNumberDataPackets.pointee = 0
                            ioData.pointee.mNumberBuffers = 1
                            ioData.pointee.mBuffers.mDataByteSize = 0
                            ioData.pointee.mBuffers.mData = nil
                            return OpusAudioEngine.noMoreInputStatus
                        }
                        let box = Unmanaged<ReusableOpusInputBox>.fromOpaque(inUserData).takeUnretainedValue()
                        if box.consumed {
                            // Signal temporary starvation (QA1317) — never return noErr+0 or Opus enters permanent EOF!
                            ioNumberDataPackets.pointee = 0
                            ioData.pointee.mNumberBuffers = 1
                            ioData.pointee.mBuffers.mDataByteSize = 0
                            ioData.pointee.mBuffers.mData = nil
                            return OpusAudioEngine.noMoreInputStatus
                        }
                        box.consumed = true
                        ioNumberDataPackets.pointee = 1
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = box.channels
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(box.byteCount)
                        ioData.pointee.mBuffers.mData = box.storage
                        if let outDescPtr = outDataPacketDescription {
                            outDescPtr.pointee = box.packetDescPtr
                        }
                        return noErr
                    },
                    userData,
                    &ioOutputFrames,
                    &outBufferList,
                    nil
                )
            }
        }

        if (status == noErr || status == Self.noMoreInputStatus), ioOutputFrames > 0 {
            let decodedSamples = Int(ioOutputFrames) * channels
            writeToRing(samples: decodeScratchPCM, count: decodedSamples)
            if let tap = pcmTap {
                tap(Array(decodeScratchPCM.prefix(decodedSamples)), Int(ioOutputFrames), outputSampleRate, channels)
            }
        }
    }

    /// RFC 6716 Section 3.1/3.2 Opus TOC byte parser to compute exact PCM frames per packet.
    static func estimateOpusFrameCount(packet: Data, sampleRate: Int = 48_000) -> Int {
        guard let toc = packet.first else { return sampleRate * 20 / 1000 }
        let config = Int(toc >> 3)
        let frameCode = Int(toc & 0x03)

        let frameDurationUs: Int
        if config < 12 {
            let rem = config % 4
            frameDurationUs = [10_000, 20_000, 40_000, 60_000][rem]
        } else if config < 16 {
            frameDurationUs = (config % 2 == 0) ? 10_000 : 20_000
        } else {
            let rem = (config - 16) % 4
            frameDurationUs = [2_500, 5_000, 10_000, 20_000][rem]
        }

        let numFrames: Int
        switch frameCode {
        case 0: numFrames = 1
        case 1, 2: numFrames = 2
        case 3:
            numFrames = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
        default:
            numFrames = 1
        }

        let totalUs = frameDurationUs * max(numFrames, 1)
        return max((sampleRate * totalUs) / 1_000_000, 120)
    }

    // MARK: - Ring Buffer Operations (Fast `memcpy` + Adaptive Jitter Cushion)

    private func clearRingBuffer() {
        os_unfair_lock_lock(&ringLock)
        ringReadIndex = 0
        ringWriteIndex = 0
        ringCount = 0
        isPriming = true
        hasStartedPlayback = false
        fadeInRemainingFrames = 0
        lastSampleL = 0
        lastSampleR = 0
        consecutiveMissingCallbacks = 0
        os_unfair_lock_unlock(&ringLock)
    }

    private func writeToRing(samples: [Float], count: Int) {
        let now = CACurrentMediaTime()
        var cushionLogMessage: String?

        os_unfair_lock_lock(&ringLock)
        if ringCapacity > 0 && count > 0 {
            // Track inter-packet arrival burst peaks (fast attack, gentle decay) so AWDL 45-55ms
            // off-channel blackouts are absorbed proactively BEFORE any underrun happens.
            if lastPacketArrivalTime > 0 {
                let gapMs = min(max((now - lastPacketArrivalTime) * 1000.0, 0.0), 140.0)
                if gapMs > smoothedPeakGapMs {
                    smoothedPeakGapMs = gapMs
                } else {
                    // Smooth 3.0ms/sec decay holds across intermittent AWDL scans while returning promptly to ~30ms when clean
                    smoothedPeakGapMs = max(20.0, smoothedPeakGapMs - 0.06)
                }
            }
            lastPacketArrivalTime = now

            // Gently relax underrun bonus after 8s of clean playback
            if underrunBonusMs > 0 && (now - lastUnderrunTime) > 8.0 && (now - lastRelaxCheckTime) > 3.0 {
                underrunBonusMs = max(0, underrunBonusMs - 6)
                lastRelaxCheckTime = now
            }
            recomputeWatermarksLocked(sampleRate: outputSampleRate, channels: Int(outputChannels))
            if abs(primingMs - lastLoggedTargetMs) >= 16 {
                lastLoggedTargetMs = primingMs
                cushionLogMessage = "audio adaptive cushion targetMs=\(primingMs) peakGapMs=\(String(format: "%.1f", smoothedPeakGapMs))"
            }

            // Smooth drift control with true 64-frame in-place crossfade (zero clicks or volume dips)
            if ringCount + count > maxBufferedSamples {
                let desiredDrop = max(ringCount + count - targetBufferedSamples, 0)
                let alignedDrop = (min(desiredDrop, ringCount) / 2) * 2
                if alignedDrop > 0 {
                    let channels = Int(outputChannels)
                    let remainingAfterDrop = ringCount - alignedDrop
                    let crossfadeFrames = min(64, remainingAfterDrop / channels, alignedDrop / channels)
                    let oldRead = ringReadIndex
                    let newRead = (ringReadIndex + alignedDrop) % ringCapacity
                    if crossfadeFrames > 1 {
                        let denom = Float(crossfadeFrames - 1)
                        for f in 0..<crossfadeFrames {
                            let t = Float(f) / denom
                            let invT = 1.0 - t
                            for ch in 0..<channels {
                                let oldIdx = (oldRead + f * channels + ch) % ringCapacity
                                let newIdx = (newRead + f * channels + ch) % ringCapacity
                                ringBuffer[newIdx] = ringBuffer[oldIdx] * invT + ringBuffer[newIdx] * t
                            }
                        }
                    }
                    ringReadIndex = newRead
                    ringCount -= alignedDrop
                }
            }

            if count >= ringCapacity {
                let offset = count - ringCapacity
                samples.withUnsafeBufferPointer { src in
                    ringBuffer.withUnsafeMutableBufferPointer { dst in
                        if let s = src.baseAddress, let d = dst.baseAddress {
                            d.update(from: s + offset, count: ringCapacity)
                        }
                    }
                }
                ringReadIndex = 0
                ringWriteIndex = 0
                ringCount = ringCapacity
            } else {
                let freeSpace = ringCapacity - ringCount
                if count > freeSpace {
                    let overwrite = ((count - freeSpace + 1) / 2) * 2
                    ringReadIndex = (ringReadIndex + overwrite) % ringCapacity
                    ringCount = max(ringCount - overwrite, 0)
                }

                let firstChunk = min(count, ringCapacity - ringWriteIndex)
                let remainder = count - firstChunk
                samples.withUnsafeBufferPointer { src in
                    ringBuffer.withUnsafeMutableBufferPointer { dst in
                        guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                        d.advanced(by: ringWriteIndex).update(from: s, count: firstChunk)
                        if remainder > 0 {
                            d.update(from: s + firstChunk, count: remainder)
                        }
                    }
                }
                ringWriteIndex = (ringWriteIndex + count) % ringCapacity
                ringCount += count

                let threshold = hasStartedPlayback ? resumePrimingSamples : primingSamples
                if isPriming && ringCount >= threshold {
                    isPriming = false
                    hasStartedPlayback = true
                    fadeInRemainingFrames = 64
                }
            }
        }
        os_unfair_lock_unlock(&ringLock)

        if let msg = cushionLogMessage {
            Self.logger.info("\(msg, privacy: .public)")
        }
    }

    private func readFromRing(frames: Int, channels: Int, output: UnsafeMutableAudioBufferListPointer) {
        let ptr0 = output.count > 0 ? output[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let ptr1 = output.count > 1 ? output[1].mData?.assumingMemoryBound(to: Float.self) : nil

        // Darwin os_unfair_lock has kernel priority inheritance and writeToRing only does a ~2us memcpy;
        // never use trylock here because skipping a callback emits 10ms of hard-zero silence/clicks.
        os_unfair_lock_lock(&ringLock)

        if isPriming {
            os_unfair_lock_unlock(&ringLock)
            for f in 0..<frames {
                ptr0?[f] = 0
                ptr1?[f] = 0
            }
            return
        }

        let totalSamples = frames * channels
        let availableSamples = min(ringCount, totalSamples)
        let availableFrames = availableSamples / channels

        let fadeTotal: Float = 64.0
        for f in 0..<availableFrames {
            var gain: Float = 1.0
            if fadeInRemainingFrames > 0 {
                gain = 1.0 - (Float(fadeInRemainingFrames) / fadeTotal)
                fadeInRemainingFrames -= 1
            }
            let baseIdx = ringReadIndex + f * channels
            let sL = ringBuffer[baseIdx % ringCapacity] * gain
            let sR = ringBuffer[(baseIdx + 1) % ringCapacity] * gain
            lastSampleL = sL
            lastSampleR = sR
            ptr0?[f] = sL
            ptr1?[f] = sR
        }

        let consumed = availableFrames * channels
        ringReadIndex = (ringReadIndex + consumed) % ringCapacity
        ringCount -= consumed

        if availableFrames < frames {
            // Smooth decay to zero so there is never an audible click/pop
            let missing = frames - availableFrames
            let decayFrames = min(missing, 96)
            for i in 0..<decayFrames {
                let t = 1.0 - (Float(i + 1) / Float(decayFrames))
                ptr0?[availableFrames + i] = lastSampleL * t
                ptr1?[availableFrames + i] = lastSampleR * t
            }
            for i in decayFrames..<missing {
                ptr0?[availableFrames + i] = 0
                ptr1?[availableFrames + i] = 0
            }
            lastSampleL = 0
            lastSampleR = 0
            consecutiveMissingCallbacks += 1
            fadeInRemainingFrames = 64

            // Only re-enter priming after >= 30ms continuous drought (3 callbacks); brief 1-20ms
            // Wi-Fi bursts recover immediately on the next packet without an extra 50-76ms mute.
            if consecutiveMissingCallbacks >= 3 {
                underrunCount += 1
                lastUnderrunTime = CACurrentMediaTime()
                if underrunBonusMs < 28 {
                    underrunBonusMs = min(28, underrunBonusMs + 8)
                    recomputeWatermarksLocked(sampleRate: outputSampleRate, channels: channels)
                }
                isPriming = true
                consecutiveMissingCallbacks = 0
            }
        } else {
            consecutiveMissingCallbacks = 0
        }

        os_unfair_lock_unlock(&ringLock)
    }
}
