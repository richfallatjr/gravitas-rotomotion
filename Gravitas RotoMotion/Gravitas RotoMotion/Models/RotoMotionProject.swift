import AVFoundation
import Foundation

struct RotoMotionProject {
    let videoURL: URL
    let metadata: VideoMetadata

    struct VideoMetadata {
        let durationSeconds: Double
        let nominalFrameRate: Double
        let naturalSize: CGSize
    }

    static func load(videoURL: URL) async throws -> RotoMotionProject {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = tracks.first else {
            throw RotoMotionError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

        return RotoMotionProject(
            videoURL: videoURL,
            metadata: .init(
                durationSeconds: CMTimeGetSeconds(duration),
                nominalFrameRate: Double(nominalFrameRate),
                naturalSize: naturalSize
            )
        )
    }
}

enum RotoMotionError: LocalizedError {
    case noVideoTrack
    case noCaptureAvailable
    case noOutputDirectory

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "No video track found."
        case .noCaptureAvailable:
            "Run Vision extraction before exporting."
        case .noOutputDirectory:
            "No output directory selected."
        }
    }
}
