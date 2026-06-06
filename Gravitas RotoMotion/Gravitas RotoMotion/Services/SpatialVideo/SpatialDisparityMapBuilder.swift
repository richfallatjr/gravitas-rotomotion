import CoreMedia
import Foundation

enum SpatialDisparityMapBuilder {
    static func build(
        leftFrames: [SpatialDecodedEyeFrame],
        rightFrames: [SpatialDecodedEyeFrame],
        metadata: SpatialVideoCameraMetadata,
        settings: StereoDisparitySettings,
        maxFrames: Int? = nil,
        progress: ((_ stage: String, _ completedUnits: Int, _ totalUnits: Int) -> Void)? = nil
    ) throws -> SpatialDisparityMapCapture {
        let frameCount = min(leftFrames.count, rightFrames.count)
        let limit = maxFrames.map { min($0, frameCount) } ?? frameCount
        let search = max(1, settings.searchRadius)
        let step = max(1, settings.searchStep)
        let searchStepCount = Array(stride(from: -search, through: search, by: step)).count + 1
        let totalUnits = max(limit * searchStepCount, 1)

        var outFrames: [SpatialDisparityMapCapture.Frame] = []
        outFrames.reserveCapacity(limit)
        progress?("Preparing disparity maps", 0, totalUnits)

        for i in 0..<limit {
            let left = leftFrames[i]
            let right = rightFrames[i]
            let completedBeforeFrame = i * searchStepCount
            let frameLabel = "Computing disparity frame \(i + 1)/\(limit)"
            progress?(frameLabel, completedBeforeFrame, totalUnits)

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
                settings: settings,
                progress: { completedSearchSteps, _ in
                    progress?(
                        frameLabel,
                        completedBeforeFrame + completedSearchSteps,
                        totalUnits
                    )
                }
            )

            outFrames.append(dispFrame)
            progress?(
                "Computed disparity frame \(i + 1)/\(limit)",
                min((i + 1) * searchStepCount, totalUnits),
                totalUnits
            )
        }

        return SpatialDisparityMapCapture(
            schema: SpatialDisparityMapCapture.currentSchema,
            cameraMetadata: metadata,
            settings: settings,
            frames: outFrames
        )
    }
}
