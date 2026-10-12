@preconcurrency import AVFoundation

enum SegmentJoinerError: LocalizedError {
    case cannotExport

    var errorDescription: String? { "The recorded parts couldn’t be joined." }
}

/// Joins the segments of a paused-and-resumed recording into one MP4.
/// ScreenCaptureKit has no pause, so each stretch between pauses is recorded as its own file.
enum SegmentJoiner {
    static func join(_ segments: [URL], into output: URL) async throws {
        if segments.count == 1 {
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

        // Passthrough copies the H.264/AAC samples without re-encoding, so joining is fast and
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
}
