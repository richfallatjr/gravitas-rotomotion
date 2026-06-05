import Foundation

struct BakedRigAnimation: Codable {
    let schema: String
    let clipID: String
    let fps: Double
    let jointNames: [String]
    let frames: [Frame]

    struct Frame: Codable {
        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: JointTransform]
    }

    struct JointTransform: Codable {
        let localTranslationXYZ: [Double]
        let localRotationWXYZ: [Double]
        let localScaleXYZ: [Double]
    }

    func asSessionArmaturePoseBuffer() -> SessionArmaturePoseBuffer {
        .init(
            schema: "com.gravitas.rotomotion.session_armature_pose.v0",
            clipID: clipID,
            fps: fps,
            frames: frames.map { frame in
                .init(
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds,
                    joints: frame.joints.mapValues { joint in
                        .init(
                            localTranslationXYZ: joint.localTranslationXYZ,
                            localRotationWXYZ: joint.localRotationWXYZ,
                            localScaleXYZ: joint.localScaleXYZ
                        )
                    }
                )
            }
        )
    }
}
