import CoreGraphics
import Foundation
import simd

enum RotoDepthCalibrator {
    struct Result {
        let depthZ: Float
        let error: Float
        let targetBoneLength2D: Float
        let projectedBoneLength2D: Float
        let referenceBoneLength3D: Float
        let jointA: String
        let jointB: String
    }

    static func calibrateHipsToSpine(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        armature: RotoReferenceArmature,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float = -2000,
        nearZ: Float = -0.25,
        initialFarZ: Float = -3.0,
        maxFarZ: Float = -1999.0,
        iterations: Int = 72
    ) -> Result? {
        let jointA = "Hips"
        let jointB = "Spine"

        guard let hips2D = normalizedFrame.joints[jointA],
              let spine2D = normalizedFrame.joints[jointB],
              !hips2D.missing,
              !spine2D.missing else {
            return nil
        }

        guard let hipsRest = armature.restWorldPositions[jointA],
              let spineRest = armature.restWorldPositions[jointB] else {
            return nil
        }

        let restVector = spineRest - hipsRest
        let referenceLength = max(simd_length(restVector), 0.0001)

        let hipsPlane = pointOnVideoPlane(
            x: hips2D.x,
            y: hips2D.y,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        let spinePlane = pointOnVideoPlane(
            x: spine2D.x,
            y: spine2D.y,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        let targetLength = max(simd_length(spinePlane - hipsPlane), 0.0001)

        let hipsRayDirection = normalizeSafe(
            hipsPlane - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        func projectedLength(at z: Float) -> Float {
            let hips3D = pointOnRayAtZ(
                origin: cameraOrigin,
                direction: hipsRayDirection,
                z: z
            )
            let spine3D = hips3D + restVector
            let projectedHips = projectToVideoPlane(
                point: hips3D,
                cameraOrigin: cameraOrigin,
                videoPlaneZ: videoPlaneZ
            )
            let projectedSpine = projectToVideoPlane(
                point: spine3D,
                cameraOrigin: cameraOrigin,
                videoPlaneZ: videoPlaneZ
            )

            return simd_length(projectedSpine - projectedHips)
        }

        var near = nearZ
        var far = initialFarZ
        var nearLength = projectedLength(at: near)
        var farLength = projectedLength(at: far)

        while farLength > targetLength && far > maxFarZ {
            far *= 2.0
            farLength = projectedLength(at: far)
        }

        if farLength > targetLength {
            let nearError = abs(nearLength - targetLength) / targetLength
            let farError = abs(farLength - targetLength) / targetLength
            let useNear = nearError < farError

            return Result(
                depthZ: useNear ? near : far,
                error: min(nearError, farError),
                targetBoneLength2D: targetLength,
                projectedBoneLength2D: useNear ? nearLength : farLength,
                referenceBoneLength3D: referenceLength,
                jointA: jointA,
                jointB: jointB
            )
        }

        var bestZ = far
        var bestLength = farLength
        var bestError = abs(farLength - targetLength) / targetLength

        for _ in 0..<iterations {
            let mid = (near + far) * 0.5
            let midLength = projectedLength(at: mid)
            let midError = abs(midLength - targetLength) / targetLength

            if midError < bestError {
                bestError = midError
                bestZ = mid
                bestLength = midLength
            }

            if midLength > targetLength {
                near = mid
                nearLength = midLength
            } else {
                far = mid
                farLength = midLength
            }
        }

        return Result(
            depthZ: bestZ,
            error: bestError,
            targetBoneLength2D: targetLength,
            projectedBoneLength2D: bestLength,
            referenceBoneLength3D: referenceLength,
            jointA: jointA,
            jointB: jointB
        )
    }

    private static func pointOnVideoPlane(
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
        let denominator = direction.z

        guard abs(denominator) > 0.000001 else {
            return origin + direction
        }

        let t = (z - origin.z) / denominator
        return origin + direction * max(t, 0)
    }

    private static func projectToVideoPlane(
        point: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>,
        videoPlaneZ: Float
    ) -> SIMD3<Float> {
        let direction = normalizeSafe(
            point - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        return pointOnRayAtZ(
            origin: cameraOrigin,
            direction: direction,
            z: videoPlaneZ
        )
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
