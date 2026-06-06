import Foundation
import simd

struct StereoVisionEnvelope {
    let jointName: String
    let leftRayOrigin: SIMD3<Double>
    let leftRayDirection: SIMD3<Double>
    let rightRayOrigin: SIMD3<Double>
    let rightRayDirection: SIMD3<Double>
    let closestPointCameraXYZ: SIMD3<Double>
    let raySeparationMeters: Double
    let stereoEnvelopeWidthPixels: Double
    let confidence: Double
}

enum StereoVisionEnvelopeBuilder {
    static func buildEnvelope(
        jointName: String,
        leftJoint: NormalizedMeshyPoseCapture.Joint,
        rightJoint: NormalizedMeshyPoseCapture.Joint,
        metadata: SpatialVideoCameraMetadata,
        yConvention: NormalizedImageYConvention
    ) -> StereoVisionEnvelope? {
        guard !leftJoint.missing,
              !rightJoint.missing,
              let baseline = metadata.baselineMeters,
              let horizontalFOV = metadata.horizontalFOVDegrees,
              baseline > 0,
              horizontalFOV > 0,
              metadata.imageWidth > 0,
              metadata.imageHeight > 0 else {
            return nil
        }

        let leftOrigin = SIMD3<Double>(-baseline * 0.5, 0, 0)
        let rightOrigin = SIMD3<Double>(baseline * 0.5, 0, 0)

        guard let leftDirection = rayDirectionFromNormalizedPoint(
            x: leftJoint.x,
            y: leftJoint.y,
            metadata: metadata,
            yConvention: yConvention
        ),
        let rightDirection = rayDirectionFromNormalizedPoint(
            x: rightJoint.x,
            y: rightJoint.y,
            metadata: metadata,
            yConvention: yConvention
        ) else {
            return nil
        }

        let closest = closestPointBetweenRays(
            o1: leftOrigin,
            d1: leftDirection,
            o2: rightOrigin,
            d2: rightDirection
        )
        let depth = max(-closest.point.z, 0.000001)
        let fovRadians = horizontalFOV * .pi / 180.0
        let focalPixels = 0.5 * Double(metadata.imageWidth) / tan(fovRadians * 0.5)
        let envelopePixels = closest.separation * focalPixels / depth

        return StereoVisionEnvelope(
            jointName: jointName,
            leftRayOrigin: leftOrigin,
            leftRayDirection: leftDirection,
            rightRayOrigin: rightOrigin,
            rightRayDirection: rightDirection,
            closestPointCameraXYZ: closest.point,
            raySeparationMeters: closest.separation,
            stereoEnvelopeWidthPixels: envelopePixels,
            confidence: min(leftJoint.confidence, rightJoint.confidence)
        )
    }

    static func rayDirectionFromNormalizedPoint(
        x: Double,
        y: Double,
        metadata: SpatialVideoCameraMetadata,
        yConvention: NormalizedImageYConvention
    ) -> SIMD3<Double>? {
        guard let horizontalFOV = metadata.horizontalFOVDegrees,
              horizontalFOV > 0,
              metadata.imageWidth > 0,
              metadata.imageHeight > 0 else {
            return nil
        }

        let width = Double(metadata.imageWidth)
        let height = Double(metadata.imageHeight)
        let focal = 0.5 * width / tan((horizontalFOV * .pi / 180.0) * 0.5)
        let cx = width * 0.5
        let cy = height * 0.5
        let px = x * width
        let py: Double

        switch yConvention {
        case .originBottomLeft:
            py = (1.0 - y) * height
        case .originTopLeft:
            py = y * height
        }

        let cameraX = (px - cx) / focal
        let cameraY = (cy - py) / focal
        let direction = SIMD3<Double>(cameraX, cameraY, -1)
        let len = simd_length(direction)

        guard len > 0.000001 else {
            return nil
        }

        return direction / len
    }

    static func closestPointBetweenRays(
        o1: SIMD3<Double>,
        d1: SIMD3<Double>,
        o2: SIMD3<Double>,
        d2: SIMD3<Double>
    ) -> (point: SIMD3<Double>, separation: Double) {
        let w0 = o1 - o2
        let a = simd_dot(d1, d1)
        let b = simd_dot(d1, d2)
        let c = simd_dot(d2, d2)
        let d = simd_dot(d1, w0)
        let e = simd_dot(d2, w0)
        let denom = a * c - b * b

        let s: Double
        let t: Double

        if abs(denom) > 0.000001 {
            s = max(0, (b * e - c * d) / denom)
            t = max(0, (a * e - b * d) / denom)
        } else {
            s = 0
            t = max(0, e / max(c, 0.000001))
        }

        let p1 = o1 + d1 * s
        let p2 = o2 + d2 * t
        let point = (p1 + p2) * 0.5

        return (
            point: point,
            separation: simd_length(p1 - p2)
        )
    }
}
