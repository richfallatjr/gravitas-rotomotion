import Foundation
import SceneKit
import simd

enum JointRotationOverrideApplier {
    static func apply(
        to session: SkinnedRigSession,
        overrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
        liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:],
        liveRotationPreviewFrameIndexByJoint: [String: Int] = [:],
        liveOverridesActive: Bool = false,
        frameIndex: Int? = nil,
        timeSeconds: Double
    ) {
        applyRotationOverrides(
            to: session,
            overrideLayer: overrideLayer,
            heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
            liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
            liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
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
        liveRotationPreviewFrameIndexByJoint: [String: Int] = [:],
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
                liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
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
        liveRotationPreviewFrameIndexByJoint: [String: Int] = [:],
        liveOverridesActive: Bool
    ) -> SIMD3<Float>? {
        _ = timeSeconds

        if let frameIndex,
           liveRotationPreviewFrameIndexByJoint[joint] == frameIndex,
           let live = liveRotationOverrideEulerXYZByJoint[joint] {
            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: live
            )
        }

        if liveOverridesActive,
           let live = liveRotationOverrideEulerXYZByJoint[joint] {
            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: live
            )
        }

        let keys = (overrideLayer.keyframesByJoint[joint] ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }

        if !keys.isEmpty {
            if let frameIndex,
               let exact = keys.first(where: { $0.frameIndex == frameIndex }) {
                return eulerFromKey(joint: joint, key: exact)
            }

            guard keys.count > 1 else {
                return eulerFromKey(joint: joint, key: keys[0])
            }

            if let frameIndex,
               frameIndex <= keys[0].frameIndex {
                return eulerFromKey(joint: joint, key: keys[0])
            }

            if let frameIndex,
               frameIndex >= keys[keys.count - 1].frameIndex {
                return eulerFromKey(
                    joint: joint,
                    key: keys[keys.count - 1]
                )
            }

            if let frameIndex {
                for i in 0..<(keys.count - 1) {
                    let a = keys[i]
                    let b = keys[i + 1]

                    guard frameIndex >= a.frameIndex,
                          frameIndex <= b.frameIndex,
                          let ea = eulerFromKey(joint: joint, key: a),
                          let eb = eulerFromKey(joint: joint, key: b) else {
                        continue
                    }

                    let denom = max(Float(b.frameIndex - a.frameIndex), 1.0)
                    let t = Float(frameIndex - a.frameIndex) / denom
                    let e = ea + (eb - ea) * t

                    return ManualRotationConstraint.clampedEulerXYZ(
                        joint: joint,
                        values: e
                    )
                }
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
            liveRotationPreviewFrameIndexByJoint: [:],
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
