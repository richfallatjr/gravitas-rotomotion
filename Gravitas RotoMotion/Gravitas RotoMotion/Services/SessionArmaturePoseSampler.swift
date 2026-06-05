import Foundation
import SceneKit
import simd

struct SessionJointTransformSample: Equatable {
    let frameIndex: Int
    let timeSeconds: Double
    let jointName: String
    let localTranslation: SIMD3<Float>
    let localRotationWXYZ: SIMD4<Float>
    let localScale: SIMD3<Float>
}

enum SessionArmaturePoseSampler {
    static func sample(
        session: SkinnedRigSession,
        frameIndex: Int,
        timeSeconds: Double
    ) -> SessionArmaturePoseBuffer.Frame {
        let samples = sampleLocalTransforms(
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            jointNodesByName: session.bonesByCanonicalName
        )

        let joints = Dictionary(
            uniqueKeysWithValues: samples.map { sample in
                (
                    sample.jointName,
                    SessionArmaturePoseBuffer.JointTransform(
                        localTranslationXYZ: [
                            Double(sample.localTranslation.x),
                            Double(sample.localTranslation.y),
                            Double(sample.localTranslation.z)
                        ],
                        localRotationWXYZ: [
                            Double(sample.localRotationWXYZ.x),
                            Double(sample.localRotationWXYZ.y),
                            Double(sample.localRotationWXYZ.z),
                            Double(sample.localRotationWXYZ.w)
                        ],
                        localScaleXYZ: [
                            Double(sample.localScale.x),
                            Double(sample.localScale.y),
                            Double(sample.localScale.z)
                        ]
                    )
                )
            }
        )

        return .init(
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            joints: joints
        )
    }

    static func sampleLocalTransforms(
        frameIndex: Int,
        timeSeconds: Double,
        jointNodesByName: [String: SCNNode]
    ) -> [SessionJointTransformSample] {
        CanonicalRig.jointNames.compactMap { jointName in
            guard let node = jointNodesByName[jointName] else {
                return nil
            }

            let q = node.simdOrientation

            return SessionJointTransformSample(
                frameIndex: frameIndex,
                timeSeconds: timeSeconds,
                jointName: jointName,
                localTranslation: node.simdPosition,
                localRotationWXYZ: SIMD4<Float>(
                    q.vector.w,
                    q.vector.x,
                    q.vector.y,
                    q.vector.z
                ),
                localScale: node.simdScale
            )
        }
    }

    static func makeSnapshot(
        samplesByFrame: [[SessionJointTransformSample]],
        rigID: String = CanonicalRig.rigID,
        rigVersion: String = CanonicalRig.rigVersion
    ) -> SessionArmatureSnapshot {
        let frames = samplesByFrame.compactMap { samples -> SessionArmatureSnapshot.Frame? in
            guard let first = samples.first else {
                return nil
            }

            let joints = Dictionary(
                uniqueKeysWithValues: samples.map { sample in
                    (
                        sample.jointName,
                        SessionArmatureSnapshot.JointTransform(
                            jointName: sample.jointName,
                            localTranslation: sample.localTranslation,
                            localRotationWXYZ: sample.localRotationWXYZ,
                            localScale: sample.localScale
                        )
                    )
                }
            )

            return SessionArmatureSnapshot.Frame(
                frameIndex: first.frameIndex,
                timeSeconds: first.timeSeconds,
                joints: joints
            )
        }

        return SessionArmatureSnapshot(
            schema: "com.gravitas.rotomotion.session_armature_snapshot.v0",
            sourceKind: "posed_armature_local_transforms",
            rigID: rigID,
            rigVersion: rigVersion,
            frameCount: frames.count,
            fps: inferredFPS(frames),
            frames: frames
        )
    }

    private static func inferredFPS(
        _ frames: [SessionArmatureSnapshot.Frame]
    ) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 24.0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }
}
