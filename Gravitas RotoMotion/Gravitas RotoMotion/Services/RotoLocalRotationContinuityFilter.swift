import Foundation
import simd

enum RotoLocalRotationContinuityFilter {
    static func stabilize(
        _ rotations: [String: SIMD4<Float>],
        previous: [String: SIMD4<Float>]?,
        maxStepDegrees: Float = 60.0
    ) -> [String: SIMD4<Float>] {
        guard let previous else {
            return rotations.mapValues(normalizeWXYZ)
        }

        let maxStepRadians = maxStepDegrees * .pi / 180.0
        var stabilized: [String: SIMD4<Float>] = [:]

        for (jointName, rotation) in rotations {
            var current = normalizeWXYZ(rotation)

            guard let previousRotation = previous[jointName] else {
                stabilized[jointName] = current
                continue
            }

            let prior = normalizeWXYZ(previousRotation)

            if dotWXYZ(prior, current) < 0 {
                current *= -1
            }

            let currentDot = min(max(dotWXYZ(prior, current), -1), 1)
            let angle = 2.0 * acos(currentDot)

            guard angle > maxStepRadians,
                  angle > 0.000001 else {
                stabilized[jointName] = current
                continue
            }

            let amount = maxStepRadians / angle
            let priorQuat = simdQuat(fromWXYZ: prior)
            let currentQuat = simdQuat(fromWXYZ: current)
            let clamped = simd_slerp(priorQuat, currentQuat, amount)

            stabilized[jointName] = wxyz(from: clamped)
        }

        return stabilized
    }

    private static func normalizeWXYZ(_ value: SIMD4<Float>) -> SIMD4<Float> {
        let lengthSquared = dotWXYZ(value, value)

        guard lengthSquared > 0.0000001 else {
            return SIMD4<Float>(1, 0, 0, 0)
        }

        return value / sqrt(lengthSquared)
    }

    private static func dotWXYZ(
        _ a: SIMD4<Float>,
        _ b: SIMD4<Float>
    ) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }

    private static func simdQuat(fromWXYZ value: SIMD4<Float>) -> simd_quatf {
        simd_quatf(
            ix: value.y,
            iy: value.z,
            iz: value.w,
            r: value.x
        )
    }

    private static func wxyz(from quat: simd_quatf) -> SIMD4<Float> {
        SIMD4<Float>(
            quat.real,
            quat.imag.x,
            quat.imag.y,
            quat.imag.z
        )
    }
}
