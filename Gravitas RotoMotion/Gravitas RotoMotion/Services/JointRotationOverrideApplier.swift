import Foundation
import SceneKit
import simd

enum JointRotationOverrideApplier {
    static func apply(
        to session: SkinnedRigSession,
        overrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:],
        liveOverridesActive: Bool = false,
        timeSeconds: Double
    ) {
        applyRotationOverrides(
            to: session,
            overrideLayer: overrideLayer,
            heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
            liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
            liveOverridesActive: liveOverridesActive,
            timeSeconds: timeSeconds
        )
    }

    static func applyRotationOverrides(
        to session: SkinnedRigSession,
        overrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveOverridesActive: Bool,
        timeSeconds: Double
    ) {
        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            if liveOverridesActive,
               let live = liveRotationOverrideEulerXYZByJoint[joint] {
                bone.simdEulerAngles = ManualRotationConstraint.clampedEulerXYZ(
                    joint: joint,
                    values: live
                )
                continue
            }

            if let keyed = interpolatedRotationOverrideEuler(
                joint: joint,
                timeSeconds: timeSeconds,
                overrideLayer: overrideLayer
            ) {
                bone.simdEulerAngles = keyed
                continue
            }

            if let held = heldRotationOverrideEulerXYZByJoint[joint] {
                bone.simdEulerAngles = ManualRotationConstraint.clampedEulerXYZ(
                    joint: joint,
                    values: held
                )
            }
        }
    }

    static func interpolatedRotationOverrideEuler(
        joint: String,
        timeSeconds: Double,
        overrideLayer: JointRotationOverrideLayer
    ) -> SIMD3<Float>? {
        guard let keys = overrideLayer.keyframesByJoint[joint],
              !keys.isEmpty else {
            return nil
        }

        let key = keys.last { $0.timeSeconds <= timeSeconds } ?? keys.first

        guard let key else {
            return nil
        }

        var values = SIMD3<Float>(
            Float(key.eulerXYZ[safe: 0] ?? 0),
            Float(key.eulerXYZ[safe: 1] ?? 0),
            Float(key.eulerXYZ[safe: 2] ?? 0)
        )
        values = ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: values
        )

        return values
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
