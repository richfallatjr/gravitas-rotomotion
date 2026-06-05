import Foundation
import SceneKit
import simd

enum JointRotationEditApplier {
    static func apply(
        to session: SkinnedRigSession,
        editLayer: JointRotationEditLayer,
        liveRotationEulerXYZByJoint: [String: SIMD3<Float>],
        timeSeconds: Double
    ) {
        applyKeyedRotationEditLayer(
            to: session,
            editLayer: editLayer,
            timeSeconds: timeSeconds
        )

        applyLiveRotationDeltaLayer(
            to: session,
            liveRotationEulerXYZByJoint: liveRotationEulerXYZByJoint
        )
    }

    static func applyKeyedRotationEditLayer(
        to session: SkinnedRigSession,
        editLayer: JointRotationEditLayer,
        timeSeconds: Double
    ) {
        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            guard let delta = interpolatedRotationDelta(
                joint: joint,
                timeSeconds: timeSeconds,
                editLayer: editLayer
            ) else {
                continue
            }

            bone.simdOrientation = bone.simdOrientation * delta
        }
    }

    static func applyLiveRotationDeltaLayer(
        to session: SkinnedRigSession,
        liveRotationEulerXYZByJoint: [String: SIMD3<Float>]
    ) {
        for (joint, eulerXYZ) in liveRotationEulerXYZByJoint {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            let delta = quaternionFromEulerXYZ(eulerXYZ)
            bone.simdOrientation = bone.simdOrientation * delta
        }
    }

    static func interpolatedRotationDelta(
        joint: String,
        timeSeconds: Double,
        editLayer: JointRotationEditLayer
    ) -> simd_quatf? {
        guard let keys = editLayer.keyframesByJoint[joint],
              !keys.isEmpty else {
            return nil
        }

        let key: JointRotationEditLayer.Keyframe?

        if editLayer.cleanKeysEnabled {
            key = keys.first
        } else {
            key = keys.last { $0.timeSeconds <= timeSeconds } ?? keys.first
        }

        guard let key else {
            return nil
        }

        var values = SIMD3<Float>(
            Float(key.eulerXYZ[safe: 0] ?? 0),
            Float(key.eulerXYZ[safe: 1] ?? 0),
            Float(key.eulerXYZ[safe: 2] ?? 0)
        )
        values = ManualRotationConstraint.clampedAxisValues(
            joint: joint,
            values: values
        )

        return quaternionFromEulerXYZ(values)
    }

    static func quaternionFromEulerXYZ(_ values: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(
            angle: values.x,
            axis: SIMD3<Float>(1, 0, 0)
        )
        let qy = simd_quatf(
            angle: values.y,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let qz = simd_quatf(
            angle: values.z,
            axis: SIMD3<Float>(0, 0, 1)
        )

        return qz * qy * qx
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}
