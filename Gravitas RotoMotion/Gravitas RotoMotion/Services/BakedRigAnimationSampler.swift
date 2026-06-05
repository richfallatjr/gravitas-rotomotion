import Foundation
import SceneKit
import simd

enum BakedRigAnimationSampler {
    static func sample(
        session: SkinnedRigSession,
        frameIndex: Int,
        timeSeconds: Double,
        jointNames: [String]
    ) -> BakedRigAnimation.Frame {
        var joints: [String: BakedRigAnimation.JointTransform] = [:]

        for joint in jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            let p = bone.simdPosition
            let euler = bone.simdEulerAngles
            let s = bone.simdScale

            joints[joint] = .init(
                localTranslationXYZ: [
                    Double(p.x),
                    Double(p.y),
                    Double(p.z)
                ],
                localRotationEulerXYZ: [
                    Double(euler.x),
                    Double(euler.y),
                    Double(euler.z)
                ],
                localScaleXYZ: [
                    Double(s.x),
                    Double(s.y),
                    Double(s.z)
                ]
            )
        }

        return .init(
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            joints: joints
        )
    }
}
