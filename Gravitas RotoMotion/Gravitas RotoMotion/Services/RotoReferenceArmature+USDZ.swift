import Foundation
import simd

extension RotoReferenceArmature {
    static func fromUSDZProfile(
        _ profile: USDZSkeletonProfile,
        sceneUnitsPerMeter: Double,
        fallback: RotoReferenceArmature = .meshy24Default
    ) -> RotoReferenceArmature {
        let metersPerRawUnit = max(profile.unitScaleToMeters ?? 1.0, 0.000001)
        let sceneUnitsPerMeter = max(sceneUnitsPerMeter, 0.0001)
        let rawToScene = metersPerRawUnit * sceneUnitsPerMeter

        return RotoReferenceArmature(
            rigID: fallback.rigID,
            rigVersion: fallback.rigVersion,
            joints: fallback.joints.map { joint in
                let measuredLength = profile.boneLengths[joint.name].map {
                    max($0 * rawToScene, 0.0001)
                }
                let fallbackLength = max(joint.boneLengthToParent * sceneUnitsPerMeter, 0.0001)
                let length = measuredLength ?? fallbackLength
                let direction = normalizeSafe(
                    joint.restLocalPosition.simdFloat,
                    fallback: fallbackDirection(for: joint.name)
                )

                return Joint(
                    name: joint.name,
                    parent: joint.parent,
                    restLocalPosition: .init(
                        x: Double(direction.x) * length,
                        y: Double(direction.y) * length,
                        z: Double(direction.z) * length
                    ),
                    boneLengthToParent: length
                )
            }
        )
    }

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let len2 = simd_dot(value, value)

        guard len2 > 0.000001 else {
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
