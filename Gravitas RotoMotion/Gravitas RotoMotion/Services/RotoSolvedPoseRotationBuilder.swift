import Foundation
import simd

enum RotoSolvedPoseRotationBuilder {
    static func buildLocalRotationsEulerXYZ(
        armature: RotoReferenceArmature,
        jointPositions: [String: SIMD3<Float>]
    ) -> [String: SIMD3<Float>] {
        let jointByName = armature.jointByName
        var rotations: [String: SIMD3<Float>] = [:]

        for joint in armature.joints {
            guard let parentName = joint.parent,
                  let parentPosition = jointPositions[parentName],
                  let jointPosition = jointPositions[joint.name],
                  let restJoint = jointByName[joint.name] else {
                rotations[joint.name] = SIMD3<Float>(0, 0, 0)
                continue
            }

            let restDirection = normalizeSafe(
                restJoint.restLocalPosition.simdFloat,
                fallback: fallbackDirection(for: joint.name)
            )
            let solvedDirection = normalizeSafe(
                jointPosition - parentPosition,
                fallback: restDirection
            )
            let q = simd_quatf(
                from: restDirection,
                to: solvedDirection
            )

            rotations[joint.name] = RotationEulerConverter.eulerXYZ(from: q)
        }

        return rotations
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

    private static func fallbackDirection(
        for jointName: String
    ) -> SIMD3<Float> {
        if jointName.contains("Left") {
            return SIMD3<Float>(-1, 0, 0)
        }

        if jointName.contains("Right") {
            return SIMD3<Float>(1, 0, 0)
        }

        if jointName.contains("Leg") || jointName.contains("Foot") || jointName.contains("Toe") {
            return SIMD3<Float>(0, -1, 0)
        }

        return SIMD3<Float>(0, 1, 0)
    }
}
