import CoreGraphics
import Foundation
import SceneKit
import simd

enum SkinnedRigPlacementSolver {
    static func placeRig(
        session: SkinnedRigSession,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        rootDepthZ: Float,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) {
        guard let hips = normalizedFrame.joints["Hips"],
              !hips.missing else {
            session.displayRootNode.simdPosition = SIMD3<Float>(0, 0, rootDepthZ)
            return
        }

        let pointOnPlane = SIMD3<Float>(
            Float((CGFloat(hips.x) - 0.5) * videoPlaneSize.width),
            Float((CGFloat(hips.y) - 0.5) * videoPlaneSize.height),
            videoPlaneZ
        )

        let direction = normalizeSafe(
            pointOnPlane - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let denominator = direction.z
        guard abs(denominator) > 0.000001 else {
            session.displayRootNode.simdPosition = SIMD3<Float>(0, 0, rootDepthZ)
            return
        }

        let t = (rootDepthZ - cameraOrigin.z) / denominator
        let positioned = cameraOrigin + direction * max(t, 0)
        session.displayRootNode.simdPosition = positioned
    }

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard simd_length_squared(value) > 0.0000001 else {
            return fallback
        }

        return simd_normalize(value)
    }
}
