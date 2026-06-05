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
        frameIndex: Int? = nil,
        timeSeconds: Double
    ) {
        applyRotationOverrides(
            to: session,
            overrideLayer: overrideLayer,
            heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
            liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
            liveOverridesActive: liveOverridesActive,
            frameIndex: frameIndex,
            timeSeconds: timeSeconds
        )
    }

    static func applyRotationOverrides(
        to session: SkinnedRigSession,
        overrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveOverridesActive: Bool,
        frameIndex: Int?,
        timeSeconds: Double
    ) {
        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            guard let euler = rotationOverrideEuler(
                joint: joint,
                frameIndex: frameIndex,
                timeSeconds: timeSeconds,
                overrideLayer: overrideLayer,
                heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
                liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
                liveOverridesActive: liveOverridesActive
            ) else {
                continue
            }

            bone.simdEulerAngles = euler
        }
    }

    static func rotationOverrideEuler(
        joint: String,
        frameIndex: Int?,
        timeSeconds: Double,
        overrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveOverridesActive: Bool
    ) -> SIMD3<Float>? {
        _ = timeSeconds
        _ = liveOverridesActive

        let keys = (overrideLayer.keyframesByJoint[joint] ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }

        if !keys.isEmpty {
            if let frameIndex,
               let exact = keys.first(where: { $0.frameIndex == frameIndex }) {
                return eulerFromKey(joint: joint, key: exact)
            }

            if let frameIndex,
               let previous = keys.last(where: { $0.frameIndex <= frameIndex }) {
                return eulerFromKey(joint: joint, key: previous)
            }

            return eulerFromKey(joint: joint, key: keys[0])
        }

        if let live = liveRotationOverrideEulerXYZByJoint[joint] {
            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: live
            )
        }

        if let held = heldRotationOverrideEulerXYZByJoint[joint] {
            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: held
            )
        }

        return nil
    }

    static func interpolatedRotationOverrideEuler(
        joint: String,
        timeSeconds: Double,
        overrideLayer: JointRotationOverrideLayer
    ) -> SIMD3<Float>? {
        rotationOverrideEuler(
            joint: joint,
            frameIndex: nil,
            timeSeconds: timeSeconds,
            overrideLayer: overrideLayer,
            heldRotationOverrideEulerXYZByJoint: [:],
            liveRotationOverrideEulerXYZByJoint: [:],
            liveOverridesActive: false
        )
    }

    static func eulerFromKey(
        joint: String,
        key: JointRotationOverrideLayer.Keyframe
    ) -> SIMD3<Float>? {
        guard key.eulerXYZ.count == 3 else {
            return nil
        }

        let values = SIMD3<Float>(
            Float(key.eulerXYZ[safe: 0] ?? 0),
            Float(key.eulerXYZ[safe: 1] ?? 0),
            Float(key.eulerXYZ[safe: 2] ?? 0)
        )

        return ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: values
        )
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
