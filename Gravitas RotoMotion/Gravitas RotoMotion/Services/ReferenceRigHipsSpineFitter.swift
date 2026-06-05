import CoreGraphics
import Foundation
import SceneKit
import simd

enum ReferenceRigHipsSpineFitter {
    struct Result {
        let fittedZ: Float
        let error: Float
        let targetLength: Float
        let projectedLength: Float
        let hipsTargetWorld: SIMD3<Float>
        let finalRootPosition: SIMD3<Float>
    }

    static func fit(
        session: SkinnedRigSession,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float,
        searchNearZ: Float = -0.15,
        searchFarZ: Float = -50.0,
        iterations: Int = 80
    ) -> Result? {
        guard
            let hips2D = normalizedFrame.joints["Hips"],
            let spine2D = normalizedFrame.joints["Spine"],
            !hips2D.missing,
            !spine2D.missing,
            let hipsBone = session.bonesByCanonicalName["Hips"],
            let spineBone = session.bonesByCanonicalName["Spine"]
        else {
            return nil
        }

        let hipsPlane = pointOnPlane(
            x: hips2D.x,
            y: hips2D.y,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        let spinePlane = pointOnPlane(
            x: spine2D.x,
            y: spine2D.y,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        let targetLength = max(simd_length(spinePlane - hipsPlane), 0.0001)
        let hipsRay = normalizeSafe(
            hipsPlane - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let originalRootPosition = session.displayRootNode.simdPosition

        func placeRootAtHipsTarget(z: Float) -> (rootPosition: SIMD3<Float>, hipsWorld: SIMD3<Float>) {
            let desiredHips = pointOnRayAtZ(
                origin: cameraOrigin,
                direction: hipsRay,
                z: z
            )

            let currentHips = hipsBone.simdWorldPosition
            let delta = desiredHips - currentHips
            let rootPosition = session.displayRootNode.simdPosition + delta

            return (rootPosition, desiredHips)
        }

        func projectedHipsSpineLength(
            at z: Float
        ) -> (length: Float, rootPosition: SIMD3<Float>, hipsWorld: SIMD3<Float>) {
            session.displayRootNode.simdPosition = originalRootPosition

            let placed = placeRootAtHipsTarget(z: z)
            session.displayRootNode.simdPosition = placed.rootPosition

            let hipsWorld = hipsBone.simdWorldPosition
            let spineWorld = spineBone.simdWorldPosition

            let projectedHips = projectToPlane(
                point: hipsWorld,
                cameraOrigin: cameraOrigin,
                videoPlaneZ: videoPlaneZ
            )

            let projectedSpine = projectToPlane(
                point: spineWorld,
                cameraOrigin: cameraOrigin,
                videoPlaneZ: videoPlaneZ
            )

            return (
                simd_length(projectedSpine - projectedHips),
                placed.rootPosition,
                placed.hipsWorld
            )
        }

        var near = searchNearZ
        var far = searchFarZ

        var bestZ = far
        var best = projectedHipsSpineLength(at: far)
        var bestError = abs(best.length - targetLength) / targetLength

        for _ in 0..<iterations {
            let mid = (near + far) * 0.5
            let current = projectedHipsSpineLength(at: mid)
            let error = abs(current.length - targetLength) / targetLength

            if error < bestError {
                bestError = error
                bestZ = mid
                best = current
            }

            if current.length > targetLength {
                near = mid
            } else {
                far = mid
            }
        }

        session.displayRootNode.simdPosition = best.rootPosition

        return Result(
            fittedZ: bestZ,
            error: bestError,
            targetLength: targetLength,
            projectedLength: best.length,
            hipsTargetWorld: best.hipsWorld,
            finalRootPosition: best.rootPosition
        )
    }

    private static func pointOnPlane(
        x: Double,
        y: Double,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            Float((CGFloat(x) - 0.5) * videoPlaneSize.width),
            Float((CGFloat(y) - 0.5) * videoPlaneSize.height),
            videoPlaneZ
        )
    }

    private static func pointOnRayAtZ(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        z: Float
    ) -> SIMD3<Float> {
        let denom = direction.z
        guard abs(denom) > 0.000001 else {
            return origin + direction
        }

        let t = (z - origin.z) / denom
        return origin + direction * max(t, 0)
    }

    private static func projectToPlane(
        point: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>,
        videoPlaneZ: Float
    ) -> SIMD3<Float> {
        let dir = normalizeSafe(
            point - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        return pointOnRayAtZ(
            origin: cameraOrigin,
            direction: dir,
            z: videoPlaneZ
        )
    }

    private static func normalizeSafe(
        _ v: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let len2 = simd_dot(v, v)
        guard len2 > 0.000001 else {
            return fallback
        }
        return simd_normalize(v)
    }
}
