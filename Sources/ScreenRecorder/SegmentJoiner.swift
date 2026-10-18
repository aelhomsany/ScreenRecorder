@preconcurrency import AVFoundation

enum SegmentJoinerError: LocalizedError {
    case cannotExport

    var errorDescription: String? { "The recorded parts couldn’t be joined." }
}

/// Turns the recorded segments into the final MP4: joins the segments of a paused-and-resumed
/// recording (ScreenCaptureKit has no pause, so each stretch is its own file), and mixes the
/// system audio and microphone tracks into one, since many players only play the first track.
enum SegmentJoiner {
    static func join(_ segments: [URL], into output: URL) async throws {
        if segments.count == 1, try await AVURLAsset(url: segments[0]).loadTracks(withMediaType: .audio).count <= 1 {
            try FileManager.default.moveItem(at: segments[0], to: output)
            return
        }

        // Lay the segments end to end. Each segment's tracks (video, system audio, mic) go into
        // the matching composition track, matched by media type and order.
        let composition = AVMutableComposition()
        var compositionTracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            let segmentRange = CMTimeRange(start: .zero, duration: duration)

            var countByType: [AVMediaType: Int] = [:]
            for track in try await asset.load(.tracks) {
                let index = countByType[track.mediaType, default: 0]
                countByType[track.mediaType] = index + 1
                let key = "\(track.mediaType.rawValue)-\(index)"

                guard let target = compositionTracks[key]
                    ?? composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                compositionTracks[key] = target

                let range = try await track.load(.timeRange).intersection(segmentRange)
                guard range.duration > .zero else { continue }
                try target.insertTimeRange(range, of: track, at: cursor + range.start)
            }
            cursor = cursor + duration
        }

        let audioTracks = compositionTracks.keys.filter { $0.hasPrefix(AVMediaType.audio.rawValue) }.count
        if audioTracks > 1 {
            do {
                try await remuxMixingAudio(composition, to: output)
                return
            } catch {
                // Fall back to keeping the tracks separate rather than losing the recording.
            }
        }

        // Passthrough copies the video/audio samples without re-encoding, so joining is fast and
        // lossless. If that's not possible, fall back to re-encoding.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            try? FileManager.default.removeItem(at: output)
            guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            do {
                try await session.export(to: output, as: .mp4)
                return
            } catch {
                continue
            }
        }
        try? FileManager.default.removeItem(at: output)
        throw SegmentJoinerError.cannotExport
    }

    /// Copies the video as is and mixes every audio track into a single AAC track.
    private static func remuxMixingAudio(_ asset: AVAsset, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = []

        for track in try await asset.loadTracks(withMediaType: .video) {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            reader.add(readerOutput)
            writer.add(input)
            pairs.append((readerOutput, input))
        }

        let mix = AVAssetReaderAudioMixOutput(
            audioTracks: try await asset.loadTracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        reader.add(mix)
        writer.add(audioInput)
        pairs.append((mix, audioInput))

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? SegmentJoinerError.cannotExport
        }
        writer.startSession(atSourceTime: .zero)

        // Feed whichever track the writer is ready for, so the file stays interleaved.
        var active = pairs.map { _ in true }
        while active.contains(true) {
            var progressed = false
            for (index, pair) in pairs.enumerated() where active[index] && pair.input.isReadyForMoreMediaData {
                if let sample = pair.output.copyNextSampleBuffer() {
                    guard pair.input.append(sample) else {
                        reader.cancelReading()
                        throw writer.error ?? SegmentJoinerError.cannotExport
                    }
                    progressed = true
                } else {
                    pair.input.markAsFinished()
                    active[index] = false
                }
            }
            if !progressed {
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? SegmentJoinerError.cannotExport
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SegmentJoinerError.cannotExport }
    }
}
