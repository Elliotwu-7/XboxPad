import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import QuartzCore
#if os(iOS)
import Photos
#endif

/// Zero-overhead hardware HEVC/H.264 + AAC MP4 stream recorder.
/// Directly consumes decoded `CVPixelBuffer` frames from `H264StreamRenderer` and
/// decoded 48kHz Float32 PCM frames from `OpusAudioEngine` with zero screen capture overhead.
final class StreamRecorder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "recorder")

    private let queue = DispatchQueue(label: "com.elliot.xboxpad.recorder", qos: .utility)
    private var lock = os_unfair_lock()
    private var isRecordingFlag = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStarted = false
    private var startHostTime: CFTimeInterval = 0
    private var lastVideoPTS: CMTime = .invalid
    private var audioSampleOffset: Int64 = 0
    private var audioSampleRate: Double = 48_000
    private var audioChannels: Int = 2
    private var recordedWidth: Int = 0
    private var recordedHeight: Int = 0

    var isRecording: Bool {
        os_unfair_lock_lock(&lock)
        let active = isRecordingFlag
        os_unfair_lock_unlock(&lock)
        return active
    }

    func start(completion: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isRecording {
                completion(false, "已经在录制中")
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let filename = "XboxPad-\(formatter.string(from: Date())).mp4"

            let destURL: URL
            #if os(macOS)
            let fm = FileManager.default
            let moviesDir = fm.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser
            let outDir = moviesDir.appendingPathComponent("XboxPad", isDirectory: true)
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            destURL = outDir.appendingPathComponent(filename)
            #else
            destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            #endif
            try? FileManager.default.removeItem(at: destURL)

            self.outputURL = destURL
            self.writer = nil
            self.videoInput = nil
            self.pixelAdaptor = nil
            self.audioInput = nil
            self.sessionStarted = false
            self.startHostTime = 0
            self.lastVideoPTS = .invalid
            self.audioSampleOffset = 0
            self.recordedWidth = 0
            self.recordedHeight = 0

            os_unfair_lock_lock(&self.lock)
            self.isRecordingFlag = true
            os_unfair_lock_unlock(&self.lock)

            Self.logger.info("stream recorder armed -> \(destURL.lastPathComponent, privacy: .public)")
            completion(true, "已开始原画录屏")
        }
    }

    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRecording else { return }
        let pbBox = RecorderPixelBufferBox(pb: pixelBuffer)
        let now = CACurrentMediaTime()

        queue.async { [weak self] in
            guard let self, self.isRecording else { return }
            let w = CVPixelBufferGetWidth(pbBox.pb)
            let h = CVPixelBufferGetHeight(pbBox.pb)
            guard w > 0, h > 0 else { return }

            if self.writer == nil {
                guard self.prepareWriterLocked(width: w, height: h) else {
                    self.abortLocked()
                    return
                }
            }

            guard let writer = self.writer,
                  let vInput = self.videoInput,
                  let adaptor = self.pixelAdaptor,
                  writer.status == .writing else { return }

            if !self.sessionStarted {
                self.startHostTime = now
                writer.startSession(atSourceTime: .zero)
                self.sessionStarted = true
            }

            let elapsed = max(now - self.startHostTime, 0)
            var pts = CMTime(seconds: elapsed, preferredTimescale: 600)
            if self.lastVideoPTS.isValid && pts <= self.lastVideoPTS {
                pts = CMTimeAdd(self.lastVideoPTS, CMTime(value: 1, timescale: 600))
            }

            if vInput.isReadyForMoreMediaData {
                if adaptor.append(pbBox.pb, withPresentationTime: pts) {
                    self.lastVideoPTS = pts
                }
            }
        }
    }

    func appendAudioPCM(_ interleavedSamples: [Float], frameCount: Int, sampleRate: Double, channels: Int) {
        guard isRecording, frameCount > 0, channels > 0, !interleavedSamples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self,
                  self.isRecording,
                  self.sessionStarted,
                  let writer = self.writer,
                  let aInput = self.audioInput,
                  writer.status == .writing,
                  aInput.isReadyForMoreMediaData else { return }

            let sr = Int32(sampleRate > 0 ? sampleRate : self.audioSampleRate)
            let ch = UInt32(channels)
            guard let sampleBuffer = self.makeAudioSampleBuffer(
                samples: interleavedSamples,
                frameCount: frameCount,
                sampleRate: Double(sr),
                channels: ch,
                pts: CMTime(value: self.audioSampleOffset, timescale: sr)
            ) else { return }

            if aInput.append(sampleBuffer) {
                self.audioSampleOffset += Int64(frameCount)
            }
        }
    }

    func stop(completion: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false, "录屏器已释放")
                return
            }
            guard self.isRecording else {
                completion(false, "当前未在录屏")
                return
            }

            os_unfair_lock_lock(&self.lock)
            self.isRecordingFlag = false
            os_unfair_lock_unlock(&self.lock)

            guard let writer = self.writer, self.sessionStarted, let outURL = self.outputURL else {
                self.cleanupLocked()
                completion(false, "录制时间过短，未捕获到视频帧")
                return
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

            let width = self.recordedWidth
            let height = self.recordedHeight
            writer.finishWriting { [weak self] in
                let ok = writer.status == .completed
                let errMsg = writer.error?.localizedDescription ?? "未知错误"
                self?.queue.async {
                    self?.cleanupLocked()
                }
                guard ok else {
                    try? FileManager.default.removeItem(at: outURL)
                    completion(false, "录屏保存失败：\(errMsg)")
                    return
                }

                #if os(iOS)
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        try? FileManager.default.removeItem(at: outURL)
                        completion(false, "请在系统设置中允许 XboxPad 写入相册以保存录屏")
                        return
                    }
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outURL)
                    } completionHandler: { saved, saveErr in
                        try? FileManager.default.removeItem(at: outURL)
                        if saved {
                            completion(true, "原画录屏已存入相册 (\(width)×\(height))")
                        } else {
                            completion(false, "录屏写入相册失败：\(saveErr?.localizedDescription ?? "未知错误")")
                        }
                    }
                }
                #elseif os(macOS)
                completion(true, "原画录屏已存至 影片/XboxPad (\(width)×\(height))")
                #endif
            }
        }
    }

    private func prepareWriterLocked(width: Int, height: Int) -> Bool {
        guard let url = outputURL else { return false }
        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let codec: AVVideoCodecType = .hevc
            let bitrate = width >= 2500 ? 22_000_000 : 14_000_000
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                ],
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true

            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: adaptorAttrs
            )

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true

            if newWriter.canAdd(vInput) { newWriter.add(vInput) }
            if newWriter.canAdd(aInput) { newWriter.add(aInput) }

            guard newWriter.startWriting() else {
                Self.logger.error("AVAssetWriter startWriting failed: \(newWriter.error?.localizedDescription ?? "?", privacy: .public)")
                return false
            }

            self.writer = newWriter
            self.videoInput = vInput
            self.pixelAdaptor = adaptor
            self.audioInput = aInput
            self.recordedWidth = width
            self.recordedHeight = height
            return true
        } catch {
            Self.logger.error("AVAssetWriter init error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func makeAudioSampleBuffer(
        samples: [Float],
        frameCount: Int,
        sampleRate: Double,
        channels: UInt32,
        pts: CMTime
    ) -> CMSampleBuffer? {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channels
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let totalBytes = frameCount * Int(bytesPerFrame)
        guard samples.count * MemoryLayout<Float>.size >= totalBytes else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return createStatus == noErr ? sampleBuffer : nil
    }

    private func abortLocked() {
        os_unfair_lock_lock(&lock)
        isRecordingFlag = false
        os_unfair_lock_unlock(&lock)
        writer?.cancelWriting()
        if let outURL = outputURL {
            try? FileManager.default.removeItem(at: outURL)
        }
        cleanupLocked()
    }

    private func cleanupLocked() {
        writer = nil
        videoInput = nil
        pixelAdaptor = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        startHostTime = 0
        lastVideoPTS = .invalid
        audioSampleOffset = 0
    }
}

private final class RecorderPixelBufferBox: @unchecked Sendable {
    let pb: CVPixelBuffer
    init(pb: CVPixelBuffer) { self.pb = pb }
}
