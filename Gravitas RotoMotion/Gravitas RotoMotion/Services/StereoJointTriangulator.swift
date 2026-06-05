import Foundation
import simd

enum StereoJointTriangulator {
    static func triangulate(
        left: NormalizedMeshyPoseCapture,
        right: NormalizedMeshyPoseCapture,
        metadata: SpatialVideoCameraMetadata
    ) throws -> StereoMeshyJointCapture {
        guard let baselineMeters = metadata.baselineMeters,
              baselineMeters > 0 else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7401,
                userInfo: [NSLocalizedDescriptionKey: "Stereo triangulation requires an explicit baselineMeters value."]
            )
        }

        guard let horizontalFOVDegrees = metadata.horizontalFOVDegrees,
              horizontalFOVDegrees > 0,
              horizontalFOVDegrees < 180 else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7402,
                userInfo: [NSLocalizedDescriptionKey: "Stereo triangulation requires an explicit horizontalFOVDegrees value."]
            )
        }

        let width = max(Double(metadata.imageWidth), 1.0)
        let height = max(Double(metadata.imageHeight), 1.0)
        let horizontalFOVRadians = horizontalFOVDegrees * .pi / 180.0
        let focalPixels = 0.5 * width / tan(horizontalFOVRadians * 0.5)
        let cx = width * 0.5
        let cy = height * 0.5

        let rightFramesByIndex = Dictionary(
            uniqueKeysWithValues: right.frames.map { ($0.frameIndex, $0) }
        )

        let frames = left.frames.compactMap { leftFrame -> StereoMeshyJointCapture.Frame? in
            guard let rightFrame = rightFramesByIndex[leftFrame.frameIndex] else {
                return nil
            }

            var joints: [String: StereoMeshyJointCapture.Joint] = [:]

            for jointName in CanonicalRig.jointNames {
                guard let leftJoint = leftFrame.joints[jointName],
                      let rightJoint = rightFrame.joints[jointName] else {
                    continue
                }

                joints[jointName] = triangulateJoint(
                    leftJoint: leftJoint,
                    rightJoint: rightJoint,
                    width: width,
                    height: height,
                    cx: cx,
                    cy: cy,
                    focalPixels: focalPixels,
                    baselineMeters: baselineMeters
                )
            }

            return StereoMeshyJointCapture.Frame(
                frameIndex: leftFrame.frameIndex,
                timeSeconds: leftFrame.timeSeconds,
                joints: joints
            )
        }

        return StereoMeshyJointCapture(
            schema: "com.gravitas.rotomotion.stereo_meshy_joint_capture.v0",
            cameraMetadata: metadata,
            frames: frames
        )
    }

    private static func triangulateJoint(
        leftJoint: NormalizedMeshyPoseCapture.Joint,
        rightJoint: NormalizedMeshyPoseCapture.Joint,
        width: Double,
        height: Double,
        cx: Double,
        cy: Double,
        focalPixels: Double,
        baselineMeters: Double
    ) -> StereoMeshyJointCapture.Joint {
        let lx = leftJoint.x * width
        let ly = leftJoint.y * height
        let rx = rightJoint.x * width
        let ry = rightJoint.y * height

        let disparityPixels = lx - rx
        let verticalMismatchPixels = abs(ly - ry)
        let confidence = min(leftJoint.confidence, rightJoint.confidence)
        let minimumDisparityPixels = 1.0
        let disparityMagnitude = abs(disparityPixels)
        let disparityQuality = min(max(disparityMagnitude / 24.0, 0.0), 1.0)
        let stereoConfidence = confidence * disparityQuality

        let validStereo =
            !leftJoint.missing &&
            !rightJoint.missing &&
            confidence > 0.05 &&
            disparityMagnitude >= minimumDisparityPixels &&
            verticalMismatchPixels <= max(12.0, height * 0.08)

        let safeDisparity = max(disparityMagnitude, minimumDisparityPixels)
        let z = focalPixels * baselineMeters / safeDisparity
        let mx = (lx + rx) * 0.5
        let my = (ly + ry) * 0.5
        let x = (mx - cx) * z / focalPixels
        let y = -(my - cy) * z / focalPixels
        let plausibleDepth = z >= 0.2 && z <= 20.0
        let finalValidStereo = validStereo && plausibleDepth

        return StereoMeshyJointCapture.Joint(
            leftX: leftJoint.x,
            leftY: leftJoint.y,
            rightX: rightJoint.x,
            rightY: rightJoint.y,
            leftConfidence: leftJoint.confidence,
            rightConfidence: rightJoint.confidence,
            positionCameraXYZ: [x, y, -z],
            depthMeters: z,
            stereoConfidence: finalValidStereo ? stereoConfidence : 0,
            validStereo: finalValidStereo
        )
    }
}
