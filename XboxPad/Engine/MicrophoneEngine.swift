import AVFoundation
import AudioToolbox
import Foundation
import os

/// Low-latency native iPad microphone capture + Apple AudioToolbox Opus encoder
/// for Xbox Party & in-game voice chat uplink (48kHz, 20ms frames, zero external libopus).
final class MicrophoneEngine: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "mic")

    private let encodeQueue = DispatchQueue(label: "com.elliot.xboxpad.mic.encode", qos: .userInteractive)
    private var captureEngine: AVAudioEngine?
    private var resampler: AVAudioConverter?
    private var opusConverter: AudioConverterRef?
    private var isCapturing = false

    // 48kHz stereo interleaved Float32 staging ring (960 frames = 20ms per Opus packet)
    private let targetSampleRate: Double = 48_000
    private let targetChannels: UInt32 = 2
    private let opusFrameSamples = 960 // 20ms @ 48kHz
    private var pcmStaging: [Float] = []
    private var opusOutScratch = [UInt8](repeating: 0, count: 1500)
    private let encodeBox = ReusablePCMInputBox()

    /// Callback delivering encoded 20ms Opus packet + durationMs on `encodeQueue`.
    var onOpusPacket: (@Sendable (Data, UInt32) -> Void)?
    /// Callback delivering normalized microphone RMS level (0.0...1.0) throttled for UI indicator.
    var onMicLevel: (@Sendable (Float) -> Void)?

    private var lastLevelReportTime: CFAbsoluteTime = 0

    deinit {
        stop()
    }

    func requestPermissionAndStart(
        onResult: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            encodeQueue.async { [weak self] in
                guard let self else { return }
                let err = self.startLocked()
                onResult(err == nil, err)
            }
        case .denied:
            onResult(false, "请在 iPad「设置 → 隐私与安全性 → 麦克风」中允许 XboxPad 访问麦克风。")
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                guard granted, let self else {
                    onResult(false, "未授予麦克风权限，无法开启语音。")
                    return
                }
                self.encodeQueue.async {
                    let err = self.startLocked()
                    onResult(err == nil, err)
                }
            }
        @unknown default:
            onResult(false, "无法获取麦克风权限。")
        }
    }

    func stop() {
        encodeQueue.sync {
            stopLocked()
        }
    }

    // MARK: - Capture & Encode Pipeline (`encodeQueue` only)

    private func startLocked() -> String? {
        stopLocked()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setPreferredSampleRate(targetSampleRate)
            try session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)
        } catch {
            Self.logger.error("mic audio session failed: \(error.localizedDescription, privacy: .public)")
            return "麦克风音频会话启动失败：\(error.localizedDescription)"
        }

        guard setupOpusEncoderLocked() else {
            return "无法初始化 Apple Opus 语音编码器。"
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            return "未检测到可用的麦克风输入设备。"
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: true
        ) else {
            return "无法创建 48kHz PCM 格式。"
        }

        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        self.resampler = converter
        self.pcmStaging.removeAll(keepingCapacity: true)

        inputNode.installTap(onBus: 0, bufferSize: 960, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processCapturedBuffer(buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
            self.captureEngine = engine
            self.isCapturing = true
            Self.logger.info("microphone Opus uplink started hwRate=\(hwFormat.sampleRate, privacy: .public) hwCh=\(hwFormat.channelCount, privacy: .public)")
            return nil
        } catch {
            inputNode.removeTap(onBus: 0)
            Self.logger.error("mic capture engine start failed: \(error.localizedDescription, privacy: .public)")
            return "麦克风采集引擎启动失败：\(error.localizedDescription)"
        }
    }

    private func stopLocked() {
        let wasCapturing = isCapturing
        isCapturing = false
        if let engine = captureEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            captureEngine = nil
        }
        resampler = nil
        pcmStaging.removeAll(keepingCapacity: false)
        if let conv = opusConverter {
            AudioConverterDispose(conv)
            opusConverter = nil
        }
        onMicLevel?(0)

        if wasCapturing {
            // Restore pure `.playback` session so Bluetooth A2DP & iPad speakers stay at full stereo fidelity
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredSampleRate(targetSampleRate)
            try? session.setPreferredIOBufferDuration(0.010)
            try? session.setActive(true)
            Self.logger.info("microphone Opus uplink stopped & playback session restored")
        }
    }

    private func setupOpusEncoderLocked() -> Bool {
        if let conv = opusConverter {
            AudioConverterDispose(conv)
            opusConverter = nil
        }

        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * targetChannels
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: targetChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var outDesc = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(opusFrameSamples),
            mBytesPerFrame: 0,
            mChannelsPerFrame: targetChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &newConverter)
        guard status == noErr, let newConverter else {
            Self.logger.error("AudioConverterNew(PCM->Opus) failed: \(status, privacy: .public)")
            return false
        }

        var bitRate: UInt32 = 36_000
        _ = AudioConverterSetProperty(
            newConverter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitRate
        )
        opusConverter = newConverter
        return true
    }

    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let ratio = targetSampleRate / max(buffer.format.sampleRate, 8_000)
        let outCap = AVAudioFrameCount(max(Double(buffer.frameLength) * ratio + 64, 512))
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            return
        }

        let pcmCopy: [Float]
        if let resampler {
            var provided = false
            var convError: NSError?
            let status = resampler.convert(to: converted, error: &convError) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0,
                  let ptr = converted.audioBufferList.pointee.mBuffers.mData else {
                return
            }
            let floatCount = Int(converted.frameLength) * Int(targetChannels)
            let floatPtr = ptr.assumingMemoryBound(to: Float.self)
            pcmCopy = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        } else {
            return
        }

        encodeQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.enqueueAndEncodeLocked(interleavedPCM: pcmCopy)
        }
    }

    private func enqueueAndEncodeLocked(interleavedPCM: [Float]) {
        guard !interleavedPCM.isEmpty else { return }

        // Compute RMS level for live UI feedback (throttled ~15Hz)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelReportTime >= 0.065 {
            lastLevelReportTime = now
            var sumSq: Float = 0
            let step = max(interleavedPCM.count / 128, 1)
            var count = 0
            var i = 0
            while i < interleavedPCM.count {
                let s = interleavedPCM[i]
                sumSq += s * s
                count += 1
                i += step
            }
            let rms = sqrt(sumSq / Float(max(count, 1)))
            let normalized = min(max(rms * 5.0, 0), 1)
            onMicLevel?(normalized)
        }

        pcmStaging.append(contentsOf: interleavedPCM)
        let neededFloats = opusFrameSamples * Int(targetChannels)

        while pcmStaging.count >= neededFloats {
            let chunk = Array(pcmStaging.prefix(neededFloats))
            pcmStaging.removeFirst(neededFloats)
            encodeOneOpusPacketLocked(interleaved960Frames: chunk)
        }
    }

    private func encodeOneOpusPacketLocked(interleaved960Frames: [Float]) {
        guard let opusConverter else { return }
        encodeBox.prepare(samples: interleaved960Frames, channels: targetChannels)

        var ioOutputPackets: UInt32 = 1
        var outPacketDesc = AudioStreamPacketDescription()
        let maxBytes = opusOutScratch.count

        let status: OSStatus = withExtendedLifetime(encodeBox) {
            opusOutScratch.withUnsafeMutableBytes { outRaw in
                var outBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: targetChannels,
                        mDataByteSize: UInt32(maxBytes),
                        mData: outRaw.baseAddress
                    )
                )
                let userData = Unmanaged.passUnretained(encodeBox).toOpaque()
                return AudioConverterFillComplexBuffer(
                    opusConverter,
                    { _, ioNumberDataPackets, ioData, _, inUserData -> OSStatus in
                        guard let inUserData else {
                            ioNumberDataPackets.pointee = 0
                            return noErr
                        }
                        let box = Unmanaged<ReusablePCMInputBox>.fromOpaque(inUserData).takeUnretainedValue()
                        if box.consumed {
                            ioNumberDataPackets.pointee = 0
                            ioData.pointee.mNumberBuffers = 1
                            ioData.pointee.mBuffers.mDataByteSize = 0
                            ioData.pointee.mBuffers.mData = nil
                            return noErr
                        }
                        box.consumed = true
                        ioNumberDataPackets.pointee = UInt32(box.frameCount)
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = box.channels
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(box.byteCount)
                        ioData.pointee.mBuffers.mData = box.storage
                        return noErr
                    },
                    userData,
                    &ioOutputPackets,
                    &outBufferList,
                    &outPacketDesc
                )
            }
        }

        if status == noErr, ioOutputPackets > 0 {
            let byteLen = Int(outPacketDesc.mDataByteSize)
            if byteLen > 0, byteLen <= opusOutScratch.count {
                let packet = Data(opusOutScratch[0..<byteLen])
                onOpusPacket?(packet, 20)
            }
        }
    }

    private final class ReusablePCMInputBox {
        private var capacityBytes: Int = 960 * 2 * 4
        var storage: UnsafeMutableRawPointer
        var byteCount: Int = 0
        var frameCount: Int = 0
        var channels: UInt32 = 2
        var consumed = false

        init() {
            storage = UnsafeMutableRawPointer.allocate(byteCount: capacityBytes, alignment: 8)
        }

        deinit {
            storage.deallocate()
        }

        func prepare(samples: [Float], channels: UInt32) {
            let bytes = samples.count * MemoryLayout<Float>.size
            if bytes > capacityBytes {
                storage.deallocate()
                capacityBytes = max(bytes, capacityBytes * 2)
                storage = UnsafeMutableRawPointer.allocate(byteCount: capacityBytes, alignment: 8)
            }
            samples.withUnsafeBytes { raw in
                if let src = raw.baseAddress, bytes > 0 {
                    storage.copyMemory(from: src, byteCount: bytes)
                }
            }
            self.byteCount = bytes
            self.frameCount = samples.count / max(Int(channels), 1)
            self.channels = max(channels, 1)
            self.consumed = false
        }
    }
}
