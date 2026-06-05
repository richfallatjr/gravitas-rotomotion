import Foundation
import simd

enum RotoBodyBasisSolver {
    static func makeBasis(
        jointPositions: [String: SIMD3<Float>],
        previousBasis: RotoBodyBasis?,
        forceCameraFacingYaw: Bool,
        flipDotThreshold: Float = 0.15,
        stabilization: Float = 0.35
    ) -> RotoBodyBasis {
        let hips = jointPositions["Hips"] ?? .zero
        let spine = jointPositions["Spine"]
            ?? jointPositions["Spine01"]
            ?? jointPositions["Spine02"]
            ?? hips + (previousBasis?.up ?? SIMD3<Float>(0, 1, 0))
        let leftShoulder = jointPositions["LeftShoulder"]
        let rightShoulder = jointPositions["RightShoulder"]

        let up = normalizeSafe(
            spine - hips,
            fallback: previousBasis?.up ?? SIMD3<Float>(0, 1, 0)
        )

        let rightRaw: SIMD3<Float>

        if let leftShoulder, let rightShoulder {
            rightRaw = rightShoulder - leftShoulder
        } else {
            rightRaw = previousBasis?.right ?? SIMD3<Float>(1, 0, 0)
        }

        var right = normalizeSafe(
            rightRaw,
            fallback: previousBasis?.right ?? SIMD3<Float>(1, 0, 0)
        )
        right = normalizeSafe(
            right - up * simd_dot(right, up),
            fallback: previousBasis?.right ?? SIMD3<Float>(1, 0, 0)
        )

        var forward = normalizeSafe(
            simd_cross(right, up),
            fallback: previousBasis?.forward ?? SIMD3<Float>(0, 0, 1)
        )

        if forceCameraFacingYaw {
            let cameraFacing = SIMD3<Float>(0, 0, 1)

            if simd_dot(forward, cameraFacing) < 0 {
                forward *= -1
                right *= -1
            }

            forward = normalizeSafe(
                mix(forward, cameraFacing, 0.85),
                fallback: cameraFacing
            )
            right = normalizeSafe(
                simd_cross(up, forward),
                fallback: SIMD3<Float>(1, 0, 0)
            )
        }

        if let previousBasis {
            if simd_dot(forward, previousBasis.forward) < -abs(flipDotThreshold) {
                forward *= -1
                right *= -1
            }

            let t = max(0, min(stabilization, 1))
            let stabilizedUp = normalizeSafe(
                mix(previousBasis.up, up, t),
                fallback: up
            )
            var stabilizedRight = normalizeSafe(
                mix(previousBasis.right, right, t),
                fallback: right
            )
            stabilizedRight = normalizeSafe(
                stabilizedRight - stabilizedUp * simd_dot(stabilizedRight, stabilizedUp),
                fallback: right
            )
            let stabilizedForward = normalizeSafe(
                mix(previousBasis.forward, forward, t),
                fallback: forward
            )

            return makeOrthonormalBasis(
                origin: hips,
                right: stabilizedRight,
                up: stabilizedUp,
                forward: stabilizedForward,
                forceCameraFacingYaw: forceCameraFacingYaw
            )
        }

        return makeOrthonormalBasis(
            origin: hips,
            right: right,
            up: up,
            forward: forward,
            forceCameraFacingYaw: forceCameraFacingYaw
        )
    }

    private static func makeOrthonormalBasis(
        origin: SIMD3<Float>,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        forward: SIMD3<Float>,
        forceCameraFacingYaw: Bool
    ) -> RotoBodyBasis {
        let cameraFacing = SIMD3<Float>(0, 0, 1)
        var finalUp = normalizeSafe(up, fallback: SIMD3<Float>(0, 1, 0))
        var finalForward = normalizeSafe(
            forward - finalUp * simd_dot(forward, finalUp),
            fallback: forceCameraFacingYaw ? cameraFacing : SIMD3<Float>(0, 0, 1)
        )

        if forceCameraFacingYaw {
            if simd_dot(finalForward, cameraFacing) < 0 {
                finalForward *= -1
            }

            finalForward = normalizeSafe(
                mix(finalForward, cameraFacing, 0.85),
                fallback: cameraFacing
            )
        }

        var finalRight = normalizeSafe(
            simd_cross(finalUp, finalForward),
            fallback: right
        )
        finalUp = normalizeSafe(
            simd_cross(finalForward, finalRight),
            fallback: finalUp
        )

        if !forceCameraFacingYaw,
           simd_dot(finalRight, right) < 0 {
            finalRight *= -1
            finalForward *= -1
        }

        return RotoBodyBasis(
            origin: origin,
            right: finalRight,
            up: finalUp,
            forward: finalForward
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

    private static func mix(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ t: Float
    ) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
