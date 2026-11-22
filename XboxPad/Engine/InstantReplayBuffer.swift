import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import os
import QuartzCore
#if os(iOS)
import Photos
#endif

/// Zero-encode-overhead 30-second Instant Replay ring buffer.
/// Continuously retains only the last 30 seconds of compressed H.264 Annex-B Access Units
/// and Opus audio packets (~30–75 MB RAM, ~0% CPU/GPU overhead while playing).
/// On trigger, remuxes video via bit-exact `AVAssetWriter` passthrough (no re-encoding!)
/// alongside decoded AAC audio into an MP4 in under a second.
final class InstantReplayBuffer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.elliot.xboxpad", category: "replay")

    private struct VideoChunk {
        let data: Data
        let ptsUs: Int64
        let keyframe: Bool
        let arrivedAt: CFTimeInterval
    }

    private struct AudioChunk {
        let data: Data
        let sampleRate: UInt32
        let channels: UInt16
        let arrivedAt: CFTimeInterval
    }

    private let maxDurationSec: CFTimeInterval = 30.0
    private let maxVideoBytes: Int = 85 * 1024 * 1024 // 85 MB hard ceiling

    private var lock = os_unfair_lock()
    private var enabledFlag = true
    private var videoRing: [VideoChunk] = []
    private var audioRing: [AudioChunk] = []
    private var totalVideoBytes: Int = 0
    private var latestSPS: Data?
    private var latestPPS: Data?
    private var isExportingFlag = false

    private let exportQueue = DispatchQueue(label: "com.elliot.xboxpad.replay.export", qos: .userInitiated)

    func setEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        enabledFlag = enabled
        if !enabled {
            videoRing.removeAll(keepingCapacity: false)
            audioRing.removeAll(keepingCapacity: false)
            totalVideoBytes = 0
        }
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        videoRing.removeAll(keepingCapacity: false)
        audioRing.removeAll(keepingCapacity: false)
        totalVideoBytes = 0
        latestSPS = nil
        latestPPS = nil
        os_unfair_lock_unlock(&lock)
    }

    func appendVideo(data: Data, ptsUs: Int64, keyframe: Bool) {
        guard !data.isEmpty else { return }
        let now = CACurrentMediaTime()

        os_unfair_lock_lock(&lock)
        guard enabledFlag else {
            os_unfair_lock_unlock(&lock)
            return
        }
        videoRing.append(VideoChunk(data: data, ptsUs: ptsUs, keyframe: keyframe, arrivedAt: now))
        totalVideoBytes += data.count
        trimLocked(now: now)
        os_unfair_lock_unlock(&lock)
    }

    func appendAudio(data: Data, sampleRate: UInt32, channels: UInt16) {
        guard !data.isEmpty else { return }
        let now = CACurrentMediaTime()

        os_unfair_lock_lock(&lock)
        guard enabledFlag else {
            os_unfair_lock_unlock(&lock)
            return
        }
        audioRing.append(AudioChunk(data: data, sampleRate: sampleRate, channels: channels, arrivedAt: now))
        if audioRing.count > 1800 {
            audioRing.removeFirst(audioRing.count - 1600)
        }
        os_unfair_lock_unlock(&lock)
    }

    private func trimLocked(now: CFTimeInterval) {
        let cutoff = now - maxDurationSec - 2.5
        var dropCount = 0
        var bytesToDrop = 0
        while dropCount < videoRing.count {
            let chunk = videoRing[dropCount]
            let overTime = chunk.arrivedAt < cutoff
            let overMem = (totalVideoBytes - bytesToDrop) > maxVideoBytes
            if overTime || overMem {
                bytesToDrop += chunk.data.count
                dropCount += 1
            } else {
                break
            }
        }
        if dropCount > 0 {
            videoRing.removeFirst(dropCount)
            totalVideoBytes = max(0, totalVideoBytes - bytesToDrop)
        }
        if let firstVideoTime = videoRing.first?.arrivedAt {
            if let keepIdx = audioRing.firstIndex(where: { $0.arrivedAt >= firstVideoTime - 0.1 }) {
                if keepIdx > 0 {
                    audioRing.removeFirst(keepIdx)
                }
            }
        }
    }

    func exportLast30Seconds(completion: @escaping @Sendable (Bool, String) -> Void) {
        os_unfair_lock_lock(&lock)
        if !enabledFlag {
            os_unfair_lock_unlock(&lock)
            completion(false, "请先在设置中开启「精彩瞬间 30 秒回放」")
            return
        }
        if isExportingFlag {
            os_unfair_lock_unlock(&lock)
            completion(false, "正在导出回放视频，请稍候...")
            return
        }
        isExportingFlag = true
        let videoSnap = videoRing
        let audioSnap = audioRing
        os_unfair_lock_unlock(&lock)

        exportQueue.async { [weak self] in
            defer {
                if let self {
                    os_unfair_lock_lock(&self.lock)
                    self.isExportingFlag = false
                    os_unfair_lock_unlock(&self.lock)
                }
            }
            self?.performExport(videos: videoSnap, audios: audioSnap, completion: completion)
        }
    }

    private func performExport(
        videos: [VideoChunk],
        audios: [AudioChunk],
        completion: @escaping @Sendable (Bool, String) -> Void
    ) {
        guard !videos.isEmpty else {
            completion(false, "回放缓存尚无视频帧，请稍后再试")
            return
        }

        // Find SPS/PPS across the buffer and locate the first IDR keyframe inside the ~30s window.
        var foundSPS: Data?
        var foundPPS: Data?
        var firstIDRIndex: Int?

        let endTime = videos.last!.arrivedAt
        let windowStart = endTime - maxDurationSec

        for (idx, chunk) in videos.enumerated() {
            let parsed = Self.parseAnnexB(chunk.data)
            if let sps = parsed.sps { foundSPS = sps }
            if let pps = parsed.pps { foundPPS = pps }
            if (chunk.keyframe || parsed.hasIDR) && foundSPS != nil && foundPPS != nil {
                if chunk.arrivedAt >= windowStart - 4.0 && firstIDRIndex == nil {
                    firstIDRIndex = idx
                }
            }
        }
        if firstIDRIndex == nil {
            for (idx, chunk) in videos.enumerated() {
                let parsed = Self.parseAnnexB(chunk.data)
                if let sps = parsed.sps { foundSPS = sps }
                if let pps = parsed.pps { foundPPS = pps }
                if (chunk.keyframe || parsed.hasIDR) && foundSPS != nil && foundPPS != nil {
                    firstIDRIndex = idx
                    break
                }
            }
        }

        guard let startIdx = firstIDRIndex,
              let sps = foundSPS,
              let pps = foundPPS,
              let formatDesc = Self.makeVideoFormatDescription(sps: sps, pps: pps) else {
            completion(false, "回放缓存尚未包含完整关键帧，请等待 2 秒后重试")
            return
        }

        let selectedVideos = Array(videos[startIdx...])
        guard selectedVideos.count >= 10 else {
            completion(false, "回放时长过短，请稍后再保存")
            return
        }

        let clipStartTime = selectedVideos.first!.arrivedAt
        let clipDurationSec = max(selectedVideos.last!.arrivedAt - clipStartTime, 0.5)
        let selectedAudios = audios.filter { $0.arrivedAt >= clipStartTime - 0.05 && $0.arrivedAt <= endTime + 0.05 }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "XboxPad-Replay-\(formatter.string(from: Date())).mp4"
        let destURL: URL
        #if os(macOS)
        let fm = FileManager.default
        let moviesDir = fm.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let outDir = moviesDir.appendingPathComponent("XboxPad", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        destURL = outDir.appendingPathComponent(filename)
        #else
        destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        #endif
        try? FileManager.default.removeItem(at: destURL)

        do {
            let writer = try AVAssetWriter(outputURL: destURL, fileType: .mp4)
            // Passthrough H.264 remux: zero re-encoding, instantaneous export, bit-exact stream quality!
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)
            vInput.expectsMediaDataInRealTime = false
            if writer.canAdd(vInput) { writer.add(vInput) }

            let includeAudio = !selectedAudios.isEmpty
            var aInput: AVAssetWriterInput?
            if includeAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    aInput = input
                }
            }

            guard writer.startWriting() else {
                completion(false, "回放导出初始化失败：\(writer.error?.localizedDescription ?? "未知错误")")
                return
            }
            writer.startSession(atSourceTime: .zero)

            // Write video samples sequentially
            var lastVideoPTS = CMTime.invalid
            for chunk in selectedVideos {
                let parsed = Self.parseAnnexB(chunk.data)
                guard !parsed.pictureRanges.isEmpty else { continue }
                let relSec = max(chunk.arrivedAt - clipStartTime, 0)
                var pts = CMTime(seconds: relSec, preferredTimescale: 600)
                if lastVideoPTS.isValid && pts <= lastVideoPTS {
                    pts = CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: 600))
                }
                guard let sb = Self.makeAVCCSampleBuffer(
                    annexB: chunk.data,
                    ranges: parsed.pictureRanges,
                    formatDesc: formatDesc,
                    pts: pts,
                    isKeyframe: chunk.keyframe || parsed.hasIDR
                ) else { continue }

                var waitLoops = 0
                while !vInput.isReadyForMoreMediaData && writer.status == .writing && waitLoops < 200 {
                    Thread.sleep(forTimeInterval: 0.005)
                    waitLoops += 1
                }
                if vInput.isReadyForMoreMediaData && vInput.append(sb) {
                    lastVideoPTS = pts
                }
            }
            vInput.markAsFinished()

            // Decode Opus packets and append AAC audio if available
            if let aInput {
                Self.writeDecodedOpusAudio(chunks: selectedAudios, to: aInput, writer: writer)
                aInput.markAsFinished()
            }

            let sem = DispatchSemaphore(value: 0)
            writer.finishWriting {
                sem.signal()
            }
            sem.wait()

            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: destURL)
                completion(false, "回放写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
                return
            }

            let durText = "\(Int(clipDurationSec.rounded()))秒"
            #if os(iOS)
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    try? FileManager.default.removeItem(at: destURL)
                    completion(false, "请在系统设置中允许 XboxPad 写入相册以保存回放")
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destURL)
                } completionHandler: { saved, saveErr in
                    try? FileManager.default.removeItem(at: destURL)
                    if saved {
                        completion(true, "精彩回放已存入相册（过去 \(durText) 原画）")
                    } else {
                        completion(false, "回放存入相册失败：\(saveErr?.localizedDescription ?? "未知错误")")
                    }
                }
            }
            #elseif os(macOS)
            completion(true, "精彩回放已存至 影片/XboxPad（过去 \(durText) 原画）")
            #endif
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            completion(false, "回放导出异常：\(error.localizedDescription)")
        }
    }

    // MARK: - Annex-B -> AVCC Passthrough Helpers

    private struct ParsedAnnexB {
        var sps: Data?
        var pps: Data?
        var hasIDR: Bool = false
        var pictureRanges: [Range<Int>] = []
    }

    private static func parseAnnexB(_ data: Data) -> ParsedAnnexB {
        var result = ParsedAnnexB()
        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = data.count
            var i = 0
            var nalStart: Int?
            while i < count {
                var scLen = 0
                if i + 3 < count && base[i] == 0 && base[i + 1] == 0 && base[i + 2] == 0 && base[i + 3] == 1 {
                    scLen = 4
                } else if i + 2 < count && base[i] == 0 && base[i + 1] == 0 && base[i + 2] == 1 {
                    scLen = 3
                }
                if scLen > 0 {
                    if let s = nalStart, i > s { ranges.append(s..<i) }
                    i += scLen
                    nalStart = i
                } else {
                    i += 1
                }
            }
            if let s = nalStart, count > s { ranges.append(s..<count) }

            for r in ranges where !r.isEmpty {
                let nalType = base[r.lowerBound] & 0x1F
                switch nalType {
                case 7: result.sps = Data(bytes: base + r.lowerBound, count: r.count)
                case 8: result.pps = Data(bytes: base + r.lowerBound, count: r.count)
                case 5:
                    result.hasIDR = true
                    result.pictureRanges.append(r)
                case 6, 9:
                    break
                default:
                    result.pictureRanges.append(r)
                }
            }
        }
        return result
    }

    private static func makeVideoFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { sRaw in
            pps.withUnsafeBytes { pRaw in
                guard let sp = sRaw.bindMemory(to: UInt8.self).baseAddress,
                      let pp = pRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                let ptrs: [UnsafePointer<UInt8>] = [sp, pp]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        return status == noErr ? desc : nil
    }

    private static func makeAVCCSampleBuffer(
        annexB: Data,
        ranges: [Range<Int>],
        formatDesc: CMVideoFormatDescription,
        pts: CMTime,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var totalLen = 0
        for r in ranges { totalLen += 4 + r.count }
        guard totalLen > 0 else { return nil }

        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLen,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLen,
            flags: 0,
            blockBufferOut: &blockBuf
        ) == kCMBlockBufferNoErr, let block = blockBuf else { return nil }

        guard CMBlockBufferAssureBlockMemory(block) == kCMBlockBufferNoErr else { return nil }
        var dstPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dstPtr
        ) == kCMBlockBufferNoErr, let rawDst = dstPtr else { return nil }

        annexB.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.baseAddress else { return }
            let dstBase = UnsafeMutableRawPointer(rawDst)
            var offset = 0
            for r in ranges {
                var lenBE = UInt32(r.count).bigEndian
                withUnsafeBytes(of: &lenBE) { lb in
                    if let p = lb.baseAddress {
                        dstBase.advanced(by: offset).copyMemory(from: p, byteCount: 4)
                    }
                }
                offset += 4
                dstBase.advanced(by: offset).copyMemory(from: srcBase.advanced(by: r.lowerBound), byteCount: r.count)
                offset += r.count
            }
        }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = totalLen
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sb
        ) == noErr, let buffer = sb else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }
        return buffer
    }

    // MARK: - Offline Opus -> PCM -> AAC Muxing

    private static let noMoreInputStatus: OSStatus = 0x6E6F_696E

    private final class SinglePacketBox {
        var bytes: Data = Data()
        var channels: UInt32 = 2
        var consumed = false
        var desc = AudioStreamPacketDescription()
    }

    private static func writeDecodedOpusAudio(
        chunks: [AudioChunk],
        to input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) {
        guard let first = chunks.first else { return }
        let inRate = first.sampleRate > 0 ? Double(first.sampleRate) : 48_000
        let inCh = first.channels > 0 ? UInt32(first.channels) : 2
        let outRate: Double = 48_000
        let outCh: UInt32 = 2
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * outCh

        var inDesc = AudioStreamBasicDescription(
            mSampleRate: inRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: inCh,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: outRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: outCh,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inDesc, &outDesc, &conv) == noErr, let converter = conv else { return }
        defer { AudioConverterDispose(converter) }

        var pcmFormatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &outDesc,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &pcmFormatDesc
        ) == noErr, let audioFmt = pcmFormatDesc else { return }

        var pcmBuf = Array<Float>(repeating: 0, count: 5760 * Int(outCh))
        let box = SinglePacketBox()
        var sampleOffset: Int64 = 0

        for chunk in chunks {
            guard writer.status == .writing else { break }
            let expectedFrames = OpusAudioEngine.estimateOpusFrameCount(packet: chunk.data, sampleRate: Int(outRate))
            let neededFloats = expectedFrames * Int(outCh)
            if pcmBuf.count < neededFloats {
                pcmBuf = Array(repeating: 0, count: neededFloats)
            }
            box.bytes = chunk.data
            box.channels = inCh
            box.consumed = false
            box.desc = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(chunk.data.count)
            )

            var ioFrames = UInt32(expectedFrames)
            let status: OSStatus = chunk.data.withUnsafeBytes { inRaw in
                guard let inPtr = inRaw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &box.desc) { descPtr in
                    var ctx = (ptr: UnsafeMutableRawPointer(mutating: inPtr), len: UInt32(chunk.data.count), ch: inCh, desc: descPtr, done: false)
                    return withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                        pcmBuf.withUnsafeMutableBytes { outRaw in
                            var abl = AudioBufferList(
                                mNumberBuffers: 1,
                                mBuffers: AudioBuffer(
                                    mNumberChannels: outCh,
                                    mDataByteSize: UInt32(neededFloats * MemoryLayout<Float>.size),
                                    mData: outRaw.baseAddress
                                )
                            )
                            return AudioConverterFillComplexBuffer(
                                converter,
                                { _, ioNum, ioData, outPktDesc, userData -> OSStatus in
                                    guard let userData else { return InstantReplayBuffer.noMoreInputStatus }
                                    let c = userData.assumingMemoryBound(
                                        to: (ptr: UnsafeMutableRawPointer, len: UInt32, ch: UInt32, desc: UnsafeMutablePointer<AudioStreamPacketDescription>, done: Bool).self
                                    )
                                    if c.pointee.done {
                                        ioNum.pointee = 0
                                        ioData.pointee.mNumberBuffers = 1
                                        ioData.pointee.mBuffers.mDataByteSize = 0
                                        ioData.pointee.mBuffers.mData = nil
                                        return InstantReplayBuffer.noMoreInputStatus
                                    }
                                    c.pointee.done = true
                                    ioNum.pointee = 1
                                    ioData.pointee.mNumberBuffers = 1
                                    ioData.pointee.mBuffers.mNumberChannels = c.pointee.ch
                                    ioData.pointee.mBuffers.mDataByteSize = c.pointee.len
                                    ioData.pointee.mBuffers.mData = c.pointee.ptr
                                    outPktDesc?.pointee = c.pointee.desc
                                    return noErr
                                },
                                ctxPtr,
                                &ioFrames,
                                &abl,
                                nil
                            )
                        }
                    }
                }
            }

            guard (status == noErr || status == Self.noMoreInputStatus), ioFrames > 0 else { continue }
            let frameCount = Int(ioFrames)
            let totalBytes = frameCount * Int(bytesPerFrame)
            var blockBuf: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: totalBytes,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: totalBytes,
                flags: 0,
                blockBufferOut: &blockBuf
            ) == kCMBlockBufferNoErr, let bb = blockBuf else { continue }

            let copied = pcmBuf.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: bb,
                    offsetIntoDestination: 0,
                    dataLength: totalBytes
                )
            }
            guard copied == kCMBlockBufferNoErr else { continue }

            var sb: CMSampleBuffer?
            let pts = CMTime(value: sampleOffset, timescale: Int32(outRate))
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: audioFmt,
                sampleCount: frameCount,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sb
            ) == noErr, let sampleBuffer = sb else { continue }

            var waitLoops = 0
            while !input.isReadyForMoreMediaData && writer.status == .writing && waitLoops < 100 {
                Thread.sleep(forTimeInterval: 0.005)
                waitLoops += 1
            }
            if input.isReadyForMoreMediaData && input.append(sampleBuffer) {
                sampleOffset += Int64(frameCount)
            }
        }
    }
}
