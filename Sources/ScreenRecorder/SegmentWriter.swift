@preconcurrency import AVFoundation
import ScreenCaptureKit

enum VideoQuality: String, CaseIterable, Identifiable {
    case smaller, balanced, high
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smaller: "Smaller"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    /// Target bitrate. Screen content compresses very well, so these are far below what camera
    /// video needs. Scales with picture size (sub-linearly) and frame rate; H.264 needs ~50% more
    /// than HEVC for the same quality. Measured on real recordings, Balanced keeps SSIM ≈ 0.985.
    func bitrate(width: Int, height: Int, fps: Int, codec: AVVideoCodecType) -> Int {
        // Mbps for a 1-megapixel picture at 60 fps, in HEVC.
        let base: Double = switch self {
        case .smaller: 0.9
        case .balanced: 1.6
        case .high: 3.0
        }
        let megapixels = Double(width * height) / 1_000_000
        var mbps = base * pow(megapixels, 0.75) * (fps >= 60 ? 1 : 0.7)
        if codec == .h264 { mbps *= 1.5 }
        return Int(mbps * 1_000_000)
    }
}

enum SegmentWriterError: LocalizedError {
    case cannotEncode

    var errorDescription: String? { "This Mac can’t encode video with these settings." }
}

/// Writes one segment (from start/resume to pause/stop) of screen, system audio and microphone
/// samples to an MP4 with our own bitrate. ScreenCaptureKit delivers samples on `queue`, and
/// everything that touches the writer runs there.
final class SegmentWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "ScreenRecorder.writer")
    /// The codec actually used (HEVC falls back to H.264 where it isn't available).
    let codec: AVVideoCodecType

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var sessionStarted = false
    private var lastVideoTime = CMTime.zero
    private var finishing = false

    init(url: URL, width: Int, height: Int, fps: Int, quality: VideoQuality, preferHEVC: Bool,
         systemAudio captureSystemAudio: Bool, microphone captureMicrophone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: quality.bitrate(width: width, height: height, fps: fps, codec: codec),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            return [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ]
        }

        var codec: AVVideoCodecType = preferHEVC ? .hevc : .h264
        if !writer.canApply(outputSettings: videoSettings(codec), forMediaType: .video) {
            codec = .h264
        }
        guard writer.canApply(outputSettings: videoSettings(codec), forMediaType: .video) else {
            throw SegmentWriterError.cannotEncode
        }
        self.codec = codec

        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(codec))
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        // System audio and the mic go on separate tracks here; they're mixed into one when the
        // recording is finished (see SegmentJoiner), so every player hears both.
        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudio = captureSystemAudio ? audioInput(channels: 2) : nil
        microphone = captureMicrophone ? audioInput(channels: 1) : nil
        for input in [systemAudio, microphone].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }

        guard writer.startWriting() else { throw writer.error ?? SegmentWriterError.cannotEncode }
        super.init()
    }

    var error: Error? { writer.error }

    // MARK: SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, writer.status == .writing, sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // ScreenCaptureKit only sends new frames when something changes, plus "idle" ones
            // with no picture. The writer keeps showing the last frame until the next one.
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            let time = sampleBuffer.presentationTimeStamp
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            if append(sampleBuffer, to: video) { lastVideoTime = time }
        case .audio:
            if sessionStarted, let systemAudio { append(sampleBuffer, to: systemAudio) }
        case .microphone:
            if sessionStarted, let microphone { append(sampleBuffer, to: microphone) }
        @unknown default:
            break
        }
    }

    @discardableResult
    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        // Never block capture: if the encoder is behind, drop this sample.
        guard input.isReadyForMoreMediaData else { return false }
        return input.append(sample)
    }

    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }

    // MARK: Finishing

    /// Closes the file. `endTime` (host clock) is when the user paused or stopped, so a still
    /// screen at the end isn't cut short. Returns false if there's nothing usable.
    func finish(at endTime: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishing = true
                guard sessionStarted, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: false)
                    return
                }
                video.markAsFinished()
                systemAudio?.markAsFinished()
                microphone?.markAsFinished()
                writer.endSession(atSourceTime: CMTimeMaximum(endTime, lastVideoTime))
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    /// Throws the segment away (capture never started).
    func cancel() {
        queue.async { [self] in
            finishing = true
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
