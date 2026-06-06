import Foundation

struct SpatialDisparityPreviewBuildResult: Sendable {
    let previewCapture: SpatialDisparityPreviewCapture
    let dumpDirectory: URL
}

enum SpatialDisparityPreviewBuilder {
    static func buildPreviewCapture(
        disparity: SpatialDisparityMapCapture,
        progress: ((_ stage: String, _ completedFrames: Int, _ totalFrames: Int) -> Void)? = nil
    ) throws -> SpatialDisparityPreviewBuildResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotomotion_disparity_plate_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var previewFrames: [SpatialDisparityPreviewCapture.Frame] = []
        previewFrames.reserveCapacity(disparity.frames.count)
        progress?("Preparing disparity previews", 0, disparity.frames.count)

        for (index, frame) in disparity.frames.enumerated() {
            progress?(
                "Writing disparity preview \(index + 1)/\(disparity.frames.count)",
                index,
                disparity.frames.count
            )
            let stats = SpatialDisparityDebugStats.make(frame: frame)

            let depthImage = try SpatialDisparityDebugDumper.makeDepthPreviewCGImage(frame: frame)
            let confidenceImage = try SpatialDisparityDebugDumper.makeConfidencePreviewCGImage(frame: frame)
            let rawImage = try SpatialDisparityDebugDumper.makeRawDisparityPreviewCGImage(frame: frame)

            let depthURL = directory.appendingPathComponent(
                String(format: "frame_%04d_depth.png", frame.frameIndex)
            )
            let confidenceURL = directory.appendingPathComponent(
                String(format: "frame_%04d_confidence.png", frame.frameIndex)
            )
            let rawURL = directory.appendingPathComponent(
                String(format: "frame_%04d_raw_disparity.png", frame.frameIndex)
            )

            try SpatialDisparityDebugDumper.writePNG(depthImage, to: depthURL)
            try SpatialDisparityDebugDumper.writePNG(confidenceImage, to: confidenceURL)
            try SpatialDisparityDebugDumper.writePNG(rawImage, to: rawURL)

            previewFrames.append(
                SpatialDisparityPreviewCapture.Frame(
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds,
                    depthPreviewPNGPath: depthURL.path,
                    confidencePreviewPNGPath: confidenceURL.path,
                    rawDisparityPreviewPNGPath: rawURL.path,
                    validDepthPixels: stats.validDepthPixels,
                    totalPixels: stats.totalPixels,
                    minDepthMeters: stats.minDepthMeters,
                    medianDepthMeters: stats.medianDepthMeters,
                    maxDepthMeters: stats.maxDepthMeters
                )
            )
            progress?(
                "Wrote disparity preview \(index + 1)/\(disparity.frames.count)",
                previewFrames.count,
                disparity.frames.count
            )
        }

        return SpatialDisparityPreviewBuildResult(
            previewCapture: SpatialDisparityPreviewCapture(
                schema: SpatialDisparityPreviewCapture.currentSchema,
                frames: previewFrames
            ),
            dumpDirectory: directory
        )
    }
}
