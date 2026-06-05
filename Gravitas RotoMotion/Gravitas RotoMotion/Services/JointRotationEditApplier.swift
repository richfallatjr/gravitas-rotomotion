import Foundation
import SceneKit
import simd

enum JointRotationEditApplier {
    static func apply(
        to session: SkinnedRigSession,
        editLayer: JointRotationEditLayer,
        liveRotationDeltaByJoint: [String: SIMD4<Float>],
        timeSeconds: Double
    ) {
        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            let keyedDelta = interpolatedRotationDelta(
                joint: joint,
                timeSeconds: timeSeconds,
                editLayer: editLayer
            )

            let liveDelta = liveRotationDeltaByJoint[joint].map(quatFromWXYZ)

            guard let delta = liveDelta ?? keyedDelta else {
                continue
            }

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

        if editLayer.cleanKeysEnabled {
            return quatFromArray(keys[0].deltaRotationWXYZ)
        }

        let previous = keys.last { $0.timeSeconds <= timeSeconds } ?? keys.first
        return previous.map { quatFromArray($0.deltaRotationWXYZ) }
    }

    static func quatFromWXYZ(_ value: SIMD4<Float>) -> simd_quatf {
        simd_quatf(
            vector: SIMD4<Float>(
                value.y,
                value.z,
                value.w,
                value.x
            )
        )
    }

    static func quatFromArray(_ values: [Double]) -> simd_quatf {
        guard values.count == 4 else {
            return simd_quatf(
                angle: 0,
                axis: SIMD3<Float>(0, 1, 0)
            )
        }

        return simd_quatf(
            vector: SIMD4<Float>(
                Float(values[1]),
                Float(values[2]),
                Float(values[3]),
                Float(values[0])
            )
        )
    }
}
