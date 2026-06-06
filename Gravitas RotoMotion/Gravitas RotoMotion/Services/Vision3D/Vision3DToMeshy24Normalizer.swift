import Foundation

enum Vision3DToMeshy24Normalizer {
    private static let directMap: [String: String] = [
        "human_root_3D": "Hips",
        "human_left_hip_3D": "LeftUpLeg",
        "human_right_hip_3D": "RightUpLeg",
        "human_spine_3D": "Spine",
        "human_center_shoulder_3D": "neck",
        "human_center_head_3D": "Head",
        "human_top_head_3D": "head_end",
        "human_left_shoulder_3D": "LeftArm",
        "human_right_shoulder_3D": "RightArm",
        "human_left_elbow_3D": "LeftForeArm",
        "human_right_elbow_3D": "RightForeArm",
        "human_left_wrist_3D": "LeftHand",
        "human_right_wrist_3D": "RightHand",
        "human_left_knee_3D": "LeftLeg",
        "human_right_knee_3D": "RightLeg",
        "human_left_ankle_3D": "LeftFoot",
        "human_right_ankle_3D": "RightFoot"
    ]

    static func normalize(
        _ capture: Vision3DBodyPoseCapture
    ) -> NormalizedVision3DMeshyCapture {
        let frames = capture.frames.map { frame in
            NormalizedVision3DMeshyCapture.Frame(
                frameIndex: frame.frameIndex,
                timeSeconds: frame.timeSeconds,
                joints: buildCanonicalJoints(frame: frame)
            )
        }

        return NormalizedVision3DMeshyCapture(
            schema: NormalizedVision3DMeshyCapture.currentSchema,
            frames: frames
        )
    }

    private static func buildCanonicalJoints(
        frame: Vision3DBodyPoseCapture.Frame
    ) -> [String: NormalizedVision3DMeshyCapture.Joint] {
        var output: [String: NormalizedVision3DMeshyCapture.Joint] = [:]

        for (rawName, canonicalName) in directMap {
            guard let source = frame.joints[rawName],
                  source.positionXYZMeters.count == 3 else {
                continue
            }

            output[canonicalName] = NormalizedVision3DMeshyCapture.Joint(
                x: source.positionXYZMeters[0],
                y: source.positionXYZMeters[1],
                z: source.positionXYZMeters[2],
                projectedX: source.projectedX,
                projectedY: source.projectedY,
                confidence: source.confidence,
                source: rawName,
                inferred: false
            )
        }

        inferAverage("Spine02", "Hips", "Spine", 0.33, &output)
        inferAverage("Spine01", "Hips", "Spine", 0.66, &output)
        inferAverage("LeftShoulder", "neck", "LeftArm", 0.65, &output)
        inferAverage("RightShoulder", "neck", "RightArm", 0.65, &output)
        inferDuplicate("LeftToeBase", from: "LeftFoot", &output)
        inferDuplicate("RightToeBase", from: "RightFoot", &output)
        inferDuplicate("headfront", from: "Head", &output)

        for jointName in CanonicalRig.jointNames where output[jointName] == nil {
            output[jointName] = NormalizedVision3DMeshyCapture.Joint(
                x: 0,
                y: 0,
                z: 0,
                projectedX: nil,
                projectedY: nil,
                confidence: 0,
                source: "missing",
                inferred: true
            )
        }

        return output
    }

    private static func inferAverage(
        _ name: String,
        _ a: String,
        _ b: String,
        _ t: Double,
        _ output: inout [String: NormalizedVision3DMeshyCapture.Joint]
    ) {
        guard let av = output[a], let bv = output[b] else {
            return
        }

        output[name] = NormalizedVision3DMeshyCapture.Joint(
            x: av.x + (bv.x - av.x) * t,
            y: av.y + (bv.y - av.y) * t,
            z: av.z + (bv.z - av.z) * t,
            projectedX: averageOptional(av.projectedX, bv.projectedX, t),
            projectedY: averageOptional(av.projectedY, bv.projectedY, t),
            confidence: min(av.confidence, bv.confidence) * 0.5,
            source: "\(a)+\(b)",
            inferred: true
        )
    }

    private static func inferDuplicate(
        _ name: String,
        from source: String,
        _ output: inout [String: NormalizedVision3DMeshyCapture.Joint]
    ) {
        guard let sourceJoint = output[source] else {
            return
        }

        output[name] = NormalizedVision3DMeshyCapture.Joint(
            x: sourceJoint.x,
            y: sourceJoint.y,
            z: sourceJoint.z,
            projectedX: sourceJoint.projectedX,
            projectedY: sourceJoint.projectedY,
            confidence: sourceJoint.confidence * 0.25,
            source: source,
            inferred: true
        )
    }

    private static func averageOptional(
        _ a: Double?,
        _ b: Double?,
        _ t: Double
    ) -> Double? {
        guard let a, let b else {
            return a ?? b
        }

        return a + (b - a) * t
    }
}

enum Vision3DComparisonEvaluator {
    static func report(
        frame: NormalizedVision3DMeshyCapture.Frame,
        normalized2DFrame: NormalizedMeshyPoseCapture.Frame?,
        capture: NormalizedVision3DMeshyCapture?
    ) -> Vision3DComparisonReport {
        let validJoints = frame.joints.values.filter { $0.confidence > 0 }.count
        let projectedError = averageProjected2DError(
            frame: frame,
            normalized2DFrame: normalized2DFrame
        )
        let boneVariation = boneLengthVariation(
            frame: frame,
            capture: capture
        )

        return Vision3DComparisonReport(
            frameIndex: frame.frameIndex,
            validVision3DJoints: validJoints,
            averageProjected2DError: projectedError,
            averageBoneLengthVariation: boneVariation.mean,
            worstBone: boneVariation.worstBone,
            worstBoneVariation: boneVariation.worstVariation
        )
    }

    private static func averageProjected2DError(
        frame: NormalizedVision3DMeshyCapture.Frame,
        normalized2DFrame: NormalizedMeshyPoseCapture.Frame?
    ) -> Double? {
        guard let normalized2DFrame else {
            return nil
        }

        var errors: [Double] = []

        for jointName in CanonicalRig.jointNames {
            guard let joint3D = frame.joints[jointName],
                  let x3D = joint3D.projectedX,
                  let y3D = joint3D.projectedY,
                  joint3D.confidence > 0,
                  let joint2D = normalized2DFrame.joints[jointName],
                  !joint2D.missing,
                  joint2D.confidence > 0 else {
                continue
            }

            let dx = x3D - joint2D.x
            let dy = y3D - joint2D.y
            errors.append(sqrt(dx * dx + dy * dy))
        }

        guard !errors.isEmpty else {
            return nil
        }

        return errors.reduce(0, +) / Double(errors.count)
    }

    private static func boneLengthVariation(
        frame: NormalizedVision3DMeshyCapture.Frame,
        capture: NormalizedVision3DMeshyCapture?
    ) -> (
        mean: Double?,
        worstBone: String?,
        worstVariation: Double?
    ) {
        guard let capture,
              capture.frames.count > 1 else {
            return (nil, nil, nil)
        }

        var meanLengthByBone: [String: Double] = [:]

        for (a, b) in CanonicalRig.bonePairs {
            let label = "\(a)-\(b)"
            let lengths = capture.frames.compactMap {
                length(a, b, in: $0)
            }

            guard !lengths.isEmpty else {
                continue
            }

            meanLengthByBone[label] = lengths.reduce(0, +) / Double(lengths.count)
        }

        var variations: [(bone: String, value: Double)] = []

        for (a, b) in CanonicalRig.bonePairs {
            guard let current = length(a, b, in: frame) else {
                continue
            }

            let label = "\(a)-\(b)"
            guard let mean = meanLengthByBone[label],
                  mean > 0 else {
                continue
            }

            variations.append((label, abs(current - mean) / mean))
        }

        guard !variations.isEmpty else {
            return (nil, nil, nil)
        }

        let mean = variations.map(\.value).reduce(0, +) / Double(variations.count)
        let worst = variations.max { $0.value < $1.value }

        return (mean, worst?.bone, worst?.value)
    }

    private static func length(
        _ a: String,
        _ b: String,
        in frame: NormalizedVision3DMeshyCapture.Frame
    ) -> Double? {
        guard let av = frame.joints[a],
              let bv = frame.joints[b],
              av.confidence > 0,
              bv.confidence > 0 else {
            return nil
        }

        let dx = bv.x - av.x
        let dy = bv.y - av.y
        let dz = bv.z - av.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}
