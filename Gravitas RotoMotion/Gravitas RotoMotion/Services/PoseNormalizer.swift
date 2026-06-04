import Foundation

enum PoseNormalizer {
    static func normalize(
        rawCapture: RawVisionPoseCapture
    ) -> NormalizedMeshyPoseCapture {
        let frames = rawCapture.frames.map { rawFrame in
            NormalizedMeshyPoseCapture.Frame(
                frameIndex: rawFrame.frameIndex,
                timeSeconds: rawFrame.timeSeconds,
                timecode: rawFrame.timecode,
                joints: buildCanonicalJoints(rawJoints: rawFrame.joints)
            )
        }

        return NormalizedMeshyPoseCapture(
            schema: "com.gravitas.rotomotion.normalized_meshy24.v0",
            sourceRawCapturePath: nil,
            rigID: CanonicalRig.rigID,
            rigVersion: CanonicalRig.rigVersion,
            frames: frames
        )
    }

    private static func buildCanonicalJoints(
        rawJoints: [String: RawVisionPoseCapture.JointObservation]
    ) -> [String: NormalizedMeshyPoseCapture.Joint] {
        var output: [String: NormalizedMeshyPoseCapture.Joint] = [:]

        for (visionJoint, canonicalJoint) in VisionToMeshyJointMap.directMap {
            guard let raw = rawJoints[visionJoint], output[canonicalJoint] == nil else { continue }

            output[canonicalJoint] = NormalizedMeshyPoseCapture.Joint(
                x: raw.x,
                y: raw.y,
                z: nil,
                confidence: raw.confidence,
                missing: false,
                sourceVisionJoint: visionJoint,
                generated: false,
                note: nil
            )
        }

        synthesizeGeneratedJoints(into: &output)

        for jointName in CanonicalRig.jointNames where output[jointName] == nil {
            output[jointName] = NormalizedMeshyPoseCapture.Joint(
                x: 0.5,
                y: 0.5,
                z: nil,
                confidence: 0.0,
                missing: true,
                sourceVisionJoint: nil,
                generated: true,
                note: "Missing Vision evidence; placeholder only."
            )
        }

        return output
    }

    private static func synthesizeGeneratedJoints(
        into output: inout [String: NormalizedMeshyPoseCapture.Joint]
    ) {
        average("Spine02", "Hips", "neck", 0.33, &output)
        average("Spine01", "Hips", "neck", 0.55, &output)
        average("Spine", "Hips", "neck", 0.75, &output)
        average("LeftForeArm", "LeftArm", "LeftHand", 0.5, &output)
        average("RightForeArm", "RightArm", "RightHand", 0.5, &output)

        duplicate("LeftToeBase", from: "LeftFoot", output: &output)
        duplicate("RightToeBase", from: "RightFoot", output: &output)
        duplicate("head_end", from: "Head", output: &output)
        duplicate("headfront", from: "Head", output: &output)
    }

    private static func average(
        _ name: String,
        _ a: String,
        _ b: String,
        _ t: Double,
        _ output: inout [String: NormalizedMeshyPoseCapture.Joint]
    ) {
        guard let av = output[a], let bv = output[b] else { return }

        output[name] = NormalizedMeshyPoseCapture.Joint(
            x: av.x + (bv.x - av.x) * t,
            y: av.y + (bv.y - av.y) * t,
            z: nil,
            confidence: min(av.confidence, bv.confidence) * 0.5,
            missing: av.missing || bv.missing,
            sourceVisionJoint: nil,
            generated: true,
            note: "Generated from \(a) and \(b)."
        )
    }

    private static func duplicate(
        _ name: String,
        from source: String,
        output: inout [String: NormalizedMeshyPoseCapture.Joint]
    ) {
        guard let sourceJoint = output[source] else { return }

        output[name] = NormalizedMeshyPoseCapture.Joint(
            x: sourceJoint.x,
            y: sourceJoint.y,
            z: sourceJoint.z,
            confidence: sourceJoint.confidence * 0.25,
            missing: sourceJoint.missing,
            sourceVisionJoint: nil,
            generated: true,
            note: "Generated from \(source)."
        )
    }
}
