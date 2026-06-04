import Foundation

enum VisionToMeshyJointMap {
    static let directMap: [String: String] = [
        "root": "Hips",
        "leftHip": "LeftUpLeg",
        "leftKnee": "LeftLeg",
        "leftAnkle": "LeftFoot",
        "rightHip": "RightUpLeg",
        "rightKnee": "RightLeg",
        "rightAnkle": "RightFoot",
        "neck": "neck",
        "nose": "Head",
        "leftShoulder": "LeftShoulder",
        "leftElbow": "LeftArm",
        "leftWrist": "LeftHand",
        "rightShoulder": "RightShoulder",
        "rightElbow": "RightArm",
        "rightWrist": "RightHand",

        "left_upLeg_joint": "LeftUpLeg",
        "left_leg_joint": "LeftLeg",
        "left_foot_joint": "LeftFoot",
        "right_upLeg_joint": "RightUpLeg",
        "right_leg_joint": "RightLeg",
        "right_foot_joint": "RightFoot",
        "neck_1_joint": "neck",
        "head_joint": "Head",
        "left_shoulder_1_joint": "LeftShoulder",
        "left_forearm_joint": "LeftArm",
        "left_hand_joint": "LeftHand",
        "right_shoulder_1_joint": "RightShoulder",
        "right_forearm_joint": "RightArm",
        "right_hand_joint": "RightHand"
    ]

    static let generatedJoints: [String: String] = [
        "LeftToeBase": "Generated from LeftFoot forward estimate.",
        "RightToeBase": "Generated from RightFoot forward estimate.",
        "Spine02": "Generated between Hips and neck.",
        "Spine01": "Generated between Hips and neck.",
        "Spine": "Generated between Hips and neck.",
        "LeftForeArm": "Generated between LeftArm and LeftHand.",
        "RightForeArm": "Generated between RightArm and RightHand.",
        "head_end": "Generated from Head.",
        "headfront": "Generated from Head."
    ]
}

enum CanonicalPoseBuilder {
    static func buildCanonicalJoints(
        rawVisionJoints: [String: RawVisionPoseCapture.JointObservation]
    ) -> [String: RawVisionPoseCapture.CanonicalJointObservation] {
        var canonical: [String: RawVisionPoseCapture.CanonicalJointObservation] = [:]

        for (visionName, canonicalName) in VisionToMeshyJointMap.directMap {
            guard let raw = rawVisionJoints[visionName] else { continue }

            canonical[canonicalName] = RawVisionPoseCapture.CanonicalJointObservation(
                x: raw.x,
                y: raw.y,
                z: 0.0,
                confidence: raw.confidence,
                sourceVisionJoint: visionName,
                generated: false,
                note: nil
            )
        }

        synthesizeMissingCanonicalJoints(into: &canonical)

        return canonical
    }

    private static func synthesizeMissingCanonicalJoints(
        into canonical: inout [String: RawVisionPoseCapture.CanonicalJointObservation]
    ) {
        makeAverage(
            "Spine02",
            "Hips",
            "neck",
            t: 0.33,
            note: "Generated between Hips and neck.",
            canonical: &canonical
        )

        makeAverage(
            "Spine01",
            "Hips",
            "neck",
            t: 0.55,
            note: "Generated between Hips and neck.",
            canonical: &canonical
        )

        makeAverage(
            "Spine",
            "Hips",
            "neck",
            t: 0.75,
            note: "Generated between Hips and neck.",
            canonical: &canonical
        )

        makeAverage(
            "LeftForeArm",
            "LeftArm",
            "LeftHand",
            t: 0.5,
            note: "Generated between LeftArm and LeftHand.",
            canonical: &canonical
        )

        makeAverage(
            "RightForeArm",
            "RightArm",
            "RightHand",
            t: 0.5,
            note: "Generated between RightArm and RightHand.",
            canonical: &canonical
        )

        duplicate(
            "LeftToeBase",
            from: "LeftFoot",
            note: "Generated from LeftFoot.",
            canonical: &canonical
        )

        duplicate(
            "RightToeBase",
            from: "RightFoot",
            note: "Generated from RightFoot.",
            canonical: &canonical
        )

        duplicate(
            "head_end",
            from: "Head",
            note: "Generated from Head.",
            canonical: &canonical
        )

        duplicate(
            "headfront",
            from: "Head",
            note: "Generated from Head.",
            canonical: &canonical
        )

        for jointName in CanonicalRig.jointNames where canonical[jointName] == nil {
            canonical[jointName] = RawVisionPoseCapture.CanonicalJointObservation(
                x: 0.5,
                y: 0.5,
                z: 0.0,
                confidence: 0.0,
                sourceVisionJoint: nil,
                generated: true,
                note: "Missing from Vision observation; placeholder only."
            )
        }
    }

    private static func makeAverage(
        _ name: String,
        _ a: String,
        _ b: String,
        t: Double,
        note: String,
        canonical: inout [String: RawVisionPoseCapture.CanonicalJointObservation]
    ) {
        guard let av = canonical[a], let bv = canonical[b] else { return }

        canonical[name] = RawVisionPoseCapture.CanonicalJointObservation(
            x: av.x + (bv.x - av.x) * t,
            y: av.y + (bv.y - av.y) * t,
            z: 0.0,
            confidence: min(av.confidence, bv.confidence) * 0.5,
            sourceVisionJoint: nil,
            generated: true,
            note: note
        )
    }

    private static func duplicate(
        _ name: String,
        from sourceName: String,
        note: String,
        canonical: inout [String: RawVisionPoseCapture.CanonicalJointObservation]
    ) {
        guard let source = canonical[sourceName] else { return }

        canonical[name] = RawVisionPoseCapture.CanonicalJointObservation(
            x: source.x,
            y: source.y,
            z: source.z,
            confidence: source.confidence * 0.25,
            sourceVisionJoint: nil,
            generated: true,
            note: note
        )
    }
}
