import Foundation

enum SkinnedRigLocalTransformSampler {
    static func sampleFrame(
        session: SkinnedRigSession,
        frameIndex: Int,
        timeSeconds: Double
    ) -> SessionArmaturePoseBuffer.Frame {
        SessionArmaturePoseSampler.sample(
            session: session,
            frameIndex: frameIndex,
            timeSeconds: timeSeconds
        )
    }
}
