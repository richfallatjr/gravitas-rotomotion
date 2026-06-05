import AVFoundation
import Foundation

enum SpatialVideoMetadataReader {
    static func readMetadata(url: URL) async throws -> SpatialVideoCameraMetadata {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7201,
                userInfo: [NSLocalizedDescriptionKey: "Spatial video has no video track."]
            )
        }

        let naturalSize = try await track.load(.naturalSize)

        let width = max(Int(abs(naturalSize.width).rounded()), 1)
        let height = max(Int(abs(naturalSize.height).rounded()), 1)

        let metadata = SpatialVideoCameraMetadata(
            baselineMeters: nil,
            horizontalFOVDegrees: nil,
            verticalFOVDegrees: nil,
            disparityAdjustment: nil,
            imageWidth: width,
            imageHeight: height
        )

        // Apple spatial-video files carry stereo metadata in ISO BMFF boxes.
        // Baseline/FOV are kept explicit and user-editable for V1 because
        // AVFoundation does not surface those spatial boxes as stable typed
        // Swift properties here.
        print(
            """
            [SpatialVideoMetadata] video track metadata:
              imageSize: \(width)x\(height)
              baselineMeters: explicit UI value required
              horizontalFOVDegrees: explicit UI value required
              verticalFOVDegrees: explicit UI value required
            """
        )

        return metadata
    }
}
