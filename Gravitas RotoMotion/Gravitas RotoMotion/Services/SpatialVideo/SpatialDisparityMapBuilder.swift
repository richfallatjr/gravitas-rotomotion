import CoreMedia
import Foundation

enum SpatialDisparityMapBuilder {
    static func build(
        leftFrames: [SpatialDecodedEyeFrame],
        rightFrames: [SpatialDecodedEyeFrame],
        metadata: SpatialVideoCameraMetadata,
        settings: StereoDisparitySettings,
        maxFrames: Int? = nil
    ) throws -> SpatialDisparityMapCapture {
        let frameCount = min(leftFrames.count, rightFrames.count)
        let limit = maxFrames.map { min($0, frameCount) } ?? frameCount

        var outFrames: [SpatialDisparityMapCapture.Frame] = []
        outFrames.reserveCapacity(limit)

        for i in 0..<limit {
            let left = leftFrames[i]
            let right = rightFrames[i]

            let leftLum = try StereoLuminanceConverter.makeLuminanceBuffer(
                from: left.cgImage,
                scale: settings.scale
            )

            let rightLum = try StereoLuminanceConverter.makeLuminanceBuffer(
                from: right.cgImage,
                scale: settings.scale
            )

            let dispFrame = try StereoDisparityComputer.computeFrame(
                frameIndex: left.frameIndex,
                timeSeconds: CMTimeGetSeconds(left.presentationTime),
                left: leftLum,
                right: rightLum,
                metadata: metadata,
                settings: settings
            )

            outFrames.append(dispFrame)
        }

        return SpatialDisparityMapCapture(
            schema: SpatialDisparityMapCapture.currentSchema,
            cameraMetadata: metadata,
            settings: settings,
            frames: outFrames
        )
    }
}
