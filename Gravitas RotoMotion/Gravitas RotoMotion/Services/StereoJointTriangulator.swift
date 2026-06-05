import Foundation
import simd

struct StereoTriangulationSettings {
    var yConvention: NormalizedImageYConvention = .originBottomLeft
}

enum StereoJointTriangulator {
    static func triangulate(
        left: NormalizedMeshyPoseCapture,
        right: NormalizedMeshyPoseCapture,
        metadata: SpatialVideoCameraMetadata,
        settings: StereoTriangulationSettings = StereoTriangulationSettings()
    ) throws -> StereoMeshyJointCapture {
        guard let baselineMeters = metadata.baselineMeters, baselineMeters > 0 else {
            throw stereoError("Missing baselineMeters.")
        }

        guard let horizontalFOVDegrees = metadata.horizontalFOVDegrees, horizontalFOVDegrees > 0 else {
            throw stereoError("Missing horizontalFOVDegrees.")
        }

        guard metadata.imageWidth > 0, metadata.imageHeight > 0 else {
            throw stereoError("Invalid stereo image dimensions.")
        }

        let width = Double(metadata.imageWidth)
        let height = Double(metadata.imageHeight)
        let horizontalFOVRadians = horizontalFOVDegrees * .pi / 180.0
        let focalPixels = 0.5 * width / tan(horizontalFOVRadians * 0.5)
        let cx = width * 0.5
        let cy = height * 0.5

        var frames: [StereoMeshyJointCapture.Frame] = []

        for leftFrame in left.frames {
            guard let rightFrame = right.frames.min(by: {
                abs($0.timeSeconds - leftFrame.timeSeconds) < abs($1.timeSeconds - leftFrame.timeSeconds)
            }) else {
                continue
            }
            var joints: [String: StereoMeshyJointCapture.Joint] = [:]

            for jointName in CanonicalRig.jointNames {
                guard let leftJoint = leftFrame.joints[jointName],
                      let rightJoint = rightFrame.joints[jointName] else {
                    continue
                }

                joints[jointName] = triangulateJoint(
                    jointName: jointName,
                    leftJoint: leftJoint,
                    rightJoint: rightJoint,
                    width: width,
                    height: height,
                    cx: cx,
                    cy: cy,
                    focalPixels: focalPixels,
                    baselineMeters: baselineMeters,
                    yConvention: settings.yConvention
                )
            }

            frames.append(
                StereoMeshyJointCapture.Frame(
                    frameIndex: leftFrame.frameIndex,
                    timeSeconds: leftFrame.timeSeconds,
                    joints: joints
                )
            )
        }

        return StereoMeshyJointCapture(
            schema: StereoMeshyJointCapture.currentSchema,
            cameraMetadata: metadata,
            frames: frames
        )
    }

    private static func triangulateJoint(
        jointName: String,
        leftJoint: NormalizedMeshyPoseCapture.Joint,
        rightJoint: NormalizedMeshyPoseCapture.Joint,
        width: Double,
        height: Double,
        cx: Double,
        cy: Double,
        focalPixels: Double,
        baselineMeters: Double,
        yConvention: NormalizedImageYConvention
    ) -> StereoMeshyJointCapture.Joint {
        let leftPoint = pixelPoint(
            x: leftJoint.x,
            y: leftJoint.y,
            width: width,
            height: height,
            yConvention: yConvention
        )
        let rightPoint = pixelPoint(
            x: rightJoint.x,
            y: rightJoint.y,
            width: width,
            height: height,
            yConvention: yConvention
        )

        let lx = leftPoint.x
        let ly = leftPoint.y
        let rx = rightPoint.x
        let ry = rightPoint.y

        let disparity = lx - rx
        let verticalMismatch = abs(ly - ry)
        let minDisparityPixels = 0.25
        let maxVerticalMismatch = height * 0.05

        guard !leftJoint.missing, !rightJoint.missing else {
            return invalidJoint(
                leftJoint,
                rightJoint,
                reason: "\(jointName): missing left or right joint"
            )
        }

        guard abs(disparity) >= minDisparityPixels else {
            return invalidJoint(
                leftJoint,
                rightJoint,
                reason: "\(jointName): near-zero disparity"
            )
        }

        guard verticalMismatch <= maxVerticalMismatch else {
            return invalidJoint(
                leftJoint,
                rightJoint,
                reason: "\(jointName): vertical mismatch \(verticalMismatch)"
            )
        }

        let depth = focalPixels * baselineMeters / abs(disparity)
        let mx = (lx + rx) * 0.5
        let my = (ly + ry) * 0.5
        let x = (mx - cx) * depth / focalPixels
        let y = (cy - my) * depth / focalPixels
        let position = SIMD3<Double>(x, y, -depth)
        let projectedLeft = projectCameraPointToNormalizedImage(
            position,
            width: width,
            height: height,
            focalPixels: focalPixels,
            baselineMeters: baselineMeters,
            eye: .left,
            yConvention: yConvention
        )
        let projectedRight = projectCameraPointToNormalizedImage(
            position,
            width: width,
            height: height,
            focalPixels: focalPixels,
            baselineMeters: baselineMeters,
            eye: .right,
            yConvention: yConvention
        )
        let leftError = hypot(
            projectedLeft.x - leftJoint.x,
            projectedLeft.y - leftJoint.y
        )
        let rightError = hypot(
            projectedRight.x - rightJoint.x,
            projectedRight.y - rightJoint.y
        )

        return StereoMeshyJointCapture.Joint(
            leftX: leftJoint.x,
            leftY: leftJoint.y,
            rightX: rightJoint.x,
            rightY: rightJoint.y,
            leftConfidence: leftJoint.confidence,
            rightConfidence: rightJoint.confidence,
            positionCameraXYZ: [
                position.x,
                position.y,
                position.z
            ],
            depthMeters: depth,
            stereoConfidence: min(leftJoint.confidence, rightJoint.confidence),
            validStereo: true,
            rejectReason: nil,
            reprojectedLeftX: projectedLeft.x,
            reprojectedLeftY: projectedLeft.y,
            reprojectedRightX: projectedRight.x,
            reprojectedRightY: projectedRight.y,
            reprojectionErrorLeft: leftError,
            reprojectionErrorRight: rightError
        )
    }

    private static func invalidJoint(
        _ leftJoint: NormalizedMeshyPoseCapture.Joint,
        _ rightJoint: NormalizedMeshyPoseCapture.Joint,
        reason: String
    ) -> StereoMeshyJointCapture.Joint {
        StereoMeshyJointCapture.Joint(
            leftX: leftJoint.x,
            leftY: leftJoint.y,
            rightX: rightJoint.x,
            rightY: rightJoint.y,
            leftConfidence: leftJoint.confidence,
            rightConfidence: rightJoint.confidence,
            positionCameraXYZ: [0, 0, 0],
            depthMeters: 0,
            stereoConfidence: 0,
            validStereo: false,
            rejectReason: reason,
            reprojectedLeftX: leftJoint.x,
            reprojectedLeftY: leftJoint.y,
            reprojectedRightX: rightJoint.x,
            reprojectedRightY: rightJoint.y,
            reprojectionErrorLeft: 0,
            reprojectionErrorRight: 0
        )
    }

    private static func pixelPoint(
        x normalizedX: Double,
        y normalizedY: Double,
        width: Double,
        height: Double,
        yConvention: NormalizedImageYConvention
    ) -> SIMD2<Double> {
        let px = normalizedX * width
        let py: Double

        switch yConvention {
        case .originBottomLeft:
            py = (1.0 - normalizedY) * height
        case .originTopLeft:
            py = normalizedY * height
        }

        return SIMD2<Double>(px, py)
    }

    private static func projectCameraPointToNormalizedImage(
        _ point: SIMD3<Double>,
        width: Double,
        height: Double,
        focalPixels: Double,
        baselineMeters: Double,
        eye: StereoEye,
        yConvention: NormalizedImageYConvention
    ) -> SIMD2<Double> {
        let z = max(-point.z, 0.000001)
        let eyeOffsetX: Double

        switch eye {
        case .left:
            eyeOffsetX = -baselineMeters * 0.5
        case .right:
            eyeOffsetX = baselineMeters * 0.5
        }

        let px = ((point.x - eyeOffsetX) * focalPixels / z) + width * 0.5
        let py = height * 0.5 - (point.y * focalPixels / z)
        let nx = px / width
        let ny: Double

        switch yConvention {
        case .originBottomLeft:
            ny = 1.0 - (py / height)
        case .originTopLeft:
            ny = py / height
        }

        return SIMD2<Double>(nx, ny)
    }

    private static func stereoError(_ message: String) -> NSError {
        NSError(
            domain: "RotoMotionStereo",
            code: 9001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
