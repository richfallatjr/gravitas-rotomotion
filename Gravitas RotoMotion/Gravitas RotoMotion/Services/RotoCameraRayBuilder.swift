import CoreGraphics
import Foundation
import simd

enum RotoCameraRayBuilder {
    static func buildRays(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float = -2000
    ) -> [String: RotoCameraRay] {
        var rays: [String: RotoCameraRay] = [:]

        for (jointName, joint) in normalizedFrame.joints {
            guard !joint.missing, joint.confidence > 0.01 else {
                continue
            }

            let pointOnPlane = pointOnVideoPlane(
                x: joint.x,
                y: joint.y,
                videoPlaneSize: videoPlaneSize,
                videoPlaneZ: videoPlaneZ
            )

            let direction = normalizeSafe(
                pointOnPlane - cameraOrigin,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            rays[jointName] = RotoCameraRay(
                jointName: jointName,
                origin: cameraOrigin,
                direction: direction,
                confidence: Float(joint.confidence)
            )
        }

        return rays
    }

    static func pointOnVideoPlane(
        x: Double,
        y: Double,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) -> SIMD3<Float> {
        let px = (CGFloat(x) - 0.5) * videoPlaneSize.width
        let py = (CGFloat(y) - 0.5) * videoPlaneSize.height

        return SIMD3<Float>(
            Float(px),
            Float(py),
            videoPlaneZ
        )
    }

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let len2 = simd_dot(value, value)

        guard len2 > 0.0000001 else {
            return fallback
        }

        return simd_normalize(value)
    }
}
