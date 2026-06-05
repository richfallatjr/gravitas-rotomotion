import Foundation

enum CanonicalRig {
    static let rigID = "GravitasMeshyBiped24"
    static let rigVersion = "001"
    static let upAxis = "Z"
    static let sourceRotationOrder = "euler_xyz_radians"

    static let jointNames: [String] = [
        "Hips",
        "LeftUpLeg",
        "LeftLeg",
        "LeftFoot",
        "LeftToeBase",
        "RightUpLeg",
        "RightLeg",
        "RightFoot",
        "RightToeBase",
        "Spine02",
        "Spine01",
        "Spine",
        "LeftShoulder",
        "LeftArm",
        "LeftForeArm",
        "LeftHand",
        "RightShoulder",
        "RightArm",
        "RightForeArm",
        "RightHand",
        "neck",
        "Head",
        "head_end",
        "headfront"
    ]

    static let jointPaths: [String] = [
        "Hips",
        "Hips/LeftUpLeg",
        "Hips/LeftUpLeg/LeftLeg",
        "Hips/LeftUpLeg/LeftLeg/LeftFoot",
        "Hips/LeftUpLeg/LeftLeg/LeftFoot/LeftToeBase",
        "Hips/RightUpLeg",
        "Hips/RightUpLeg/RightLeg",
        "Hips/RightUpLeg/RightLeg/RightFoot",
        "Hips/RightUpLeg/RightLeg/RightFoot/RightToeBase",
        "Hips/Spine02",
        "Hips/Spine02/Spine01",
        "Hips/Spine02/Spine01/Spine",
        "Hips/Spine02/Spine01/Spine/LeftShoulder",
        "Hips/Spine02/Spine01/Spine/LeftShoulder/LeftArm",
        "Hips/Spine02/Spine01/Spine/LeftShoulder/LeftArm/LeftForeArm",
        "Hips/Spine02/Spine01/Spine/LeftShoulder/LeftArm/LeftForeArm/LeftHand",
        "Hips/Spine02/Spine01/Spine/RightShoulder",
        "Hips/Spine02/Spine01/Spine/RightShoulder/RightArm",
        "Hips/Spine02/Spine01/Spine/RightShoulder/RightArm/RightForeArm",
        "Hips/Spine02/Spine01/Spine/RightShoulder/RightArm/RightForeArm/RightHand",
        "Hips/Spine02/Spine01/Spine/neck",
        "Hips/Spine02/Spine01/Spine/neck/Head",
        "Hips/Spine02/Spine01/Spine/neck/Head/head_end",
        "Hips/Spine02/Spine01/Spine/neck/Head/headfront"
    ]

    static let parentByJoint: [String: String?] = [
        "Hips": nil,
        "LeftUpLeg": "Hips",
        "LeftLeg": "LeftUpLeg",
        "LeftFoot": "LeftLeg",
        "LeftToeBase": "LeftFoot",
        "RightUpLeg": "Hips",
        "RightLeg": "RightUpLeg",
        "RightFoot": "RightLeg",
        "RightToeBase": "RightFoot",
        "Spine02": "Hips",
        "Spine01": "Spine02",
        "Spine": "Spine01",
        "LeftShoulder": "Spine",
        "LeftArm": "LeftShoulder",
        "LeftForeArm": "LeftArm",
        "LeftHand": "LeftForeArm",
        "RightShoulder": "Spine",
        "RightArm": "RightShoulder",
        "RightForeArm": "RightArm",
        "RightHand": "RightForeArm",
        "neck": "Spine",
        "Head": "neck",
        "head_end": "Head",
        "headfront": "Head"
    ]

    static let requiredLandmarks: [String] = [
        "Hips",
        "Head",
        "neck",
        "LeftHand",
        "RightHand",
        "LeftFoot",
        "RightFoot",
        "LeftToeBase",
        "RightToeBase"
    ]

    static var childrenByJoint: [String: [String]] {
        var result: [String: [String]] = [:]

        for (joint, parent) in parentByJoint {
            guard let parent else { continue }
            result[parent, default: []].append(joint)
        }

        return result
    }

    static let bonePairs: [(String, String)] = [
        ("Hips", "LeftUpLeg"),
        ("LeftUpLeg", "LeftLeg"),
        ("LeftLeg", "LeftFoot"),
        ("LeftFoot", "LeftToeBase"),
        ("Hips", "RightUpLeg"),
        ("RightUpLeg", "RightLeg"),
        ("RightLeg", "RightFoot"),
        ("RightFoot", "RightToeBase"),
        ("Hips", "Spine02"),
        ("Spine02", "Spine01"),
        ("Spine01", "Spine"),
        ("Spine", "neck"),
        ("neck", "Head"),
        ("Head", "head_end"),
        ("Head", "headfront"),
        ("Spine", "LeftShoulder"),
        ("LeftShoulder", "LeftArm"),
        ("LeftArm", "LeftForeArm"),
        ("LeftForeArm", "LeftHand"),
        ("Spine", "RightShoulder"),
        ("RightShoulder", "RightArm"),
        ("RightArm", "RightForeArm"),
        ("RightForeArm", "RightHand")
    ]
}
