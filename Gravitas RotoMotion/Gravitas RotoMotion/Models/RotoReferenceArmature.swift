import Foundation
import simd

struct RotoReferenceArmature: Codable, Equatable {
    let rigID: String
    let rigVersion: String
    let joints: [Joint]

    struct Joint: Codable, Equatable, Identifiable {
        var id: String { name }

        let name: String
        let parent: String?
        let restLocalPosition: SIMD3Codable
        let boneLengthToParent: Double
    }

    var jointByName: [String: Joint] {
        Dictionary(uniqueKeysWithValues: joints.map { ($0.name, $0) })
    }

    var restWorldPositions: [String: SIMD3<Float>] {
        var positions: [String: SIMD3<Float>] = [:]

        for joint in joints {
            let local = joint.restLocalPosition.simdFloat

            if let parent = joint.parent,
               let parentPosition = positions[parent] {
                positions[joint.name] = parentPosition + local
            } else {
                positions[joint.name] = local
            }
        }

        return positions
    }

    var restHeight: Double {
        let yValues = restWorldPositions.values.map { Double($0.y) }

        guard let minY = yValues.min(),
              let maxY = yValues.max() else {
            return 1.0
        }

        return max(maxY - minY, 0.0001)
    }

    func scaled(by scale: Double) -> RotoReferenceArmature {
        RotoReferenceArmature(
            rigID: rigID,
            rigVersion: rigVersion,
            joints: joints.map { joint in
                Joint(
                    name: joint.name,
                    parent: joint.parent,
                    restLocalPosition: .init(
                        x: joint.restLocalPosition.x * scale,
                        y: joint.restLocalPosition.y * scale,
                        z: joint.restLocalPosition.z * scale
                    ),
                    boneLengthToParent: joint.boneLengthToParent * scale
                )
            }
        )
    }

    static let meshy24Default = RotoReferenceArmature(
        rigID: CanonicalRig.rigID,
        rigVersion: CanonicalRig.rigVersion,
        joints: [
            Joint(name: "Hips", parent: nil, restLocalPosition: .init(x: 0, y: 0, z: 0), boneLengthToParent: 0),

            Joint(name: "LeftUpLeg", parent: "Hips", restLocalPosition: .init(x: -0.16, y: -0.10, z: 0), boneLengthToParent: 0.19),
            Joint(name: "LeftLeg", parent: "LeftUpLeg", restLocalPosition: .init(x: 0, y: -0.42, z: 0), boneLengthToParent: 0.42),
            Joint(name: "LeftFoot", parent: "LeftLeg", restLocalPosition: .init(x: 0, y: -0.40, z: 0), boneLengthToParent: 0.40),
            Joint(name: "LeftToeBase", parent: "LeftFoot", restLocalPosition: .init(x: 0, y: -0.05, z: 0.16), boneLengthToParent: 0.17),

            Joint(name: "RightUpLeg", parent: "Hips", restLocalPosition: .init(x: 0.16, y: -0.10, z: 0), boneLengthToParent: 0.19),
            Joint(name: "RightLeg", parent: "RightUpLeg", restLocalPosition: .init(x: 0, y: -0.42, z: 0), boneLengthToParent: 0.42),
            Joint(name: "RightFoot", parent: "RightLeg", restLocalPosition: .init(x: 0, y: -0.40, z: 0), boneLengthToParent: 0.40),
            Joint(name: "RightToeBase", parent: "RightFoot", restLocalPosition: .init(x: 0, y: -0.05, z: 0.16), boneLengthToParent: 0.17),

            Joint(name: "Spine02", parent: "Hips", restLocalPosition: .init(x: 0, y: 0.24, z: 0), boneLengthToParent: 0.24),
            Joint(name: "Spine01", parent: "Spine02", restLocalPosition: .init(x: 0, y: 0.18, z: 0), boneLengthToParent: 0.18),
            Joint(name: "Spine", parent: "Spine01", restLocalPosition: .init(x: 0, y: 0.18, z: 0), boneLengthToParent: 0.18),

            Joint(name: "LeftShoulder", parent: "Spine", restLocalPosition: .init(x: -0.20, y: 0.10, z: 0), boneLengthToParent: 0.22),
            Joint(name: "LeftArm", parent: "LeftShoulder", restLocalPosition: .init(x: -0.30, y: -0.05, z: 0), boneLengthToParent: 0.30),
            Joint(name: "LeftForeArm", parent: "LeftArm", restLocalPosition: .init(x: -0.28, y: 0, z: 0), boneLengthToParent: 0.28),
            Joint(name: "LeftHand", parent: "LeftForeArm", restLocalPosition: .init(x: -0.16, y: 0, z: 0), boneLengthToParent: 0.16),

            Joint(name: "RightShoulder", parent: "Spine", restLocalPosition: .init(x: 0.20, y: 0.10, z: 0), boneLengthToParent: 0.22),
            Joint(name: "RightArm", parent: "RightShoulder", restLocalPosition: .init(x: 0.30, y: -0.05, z: 0), boneLengthToParent: 0.30),
            Joint(name: "RightForeArm", parent: "RightArm", restLocalPosition: .init(x: 0.28, y: 0, z: 0), boneLengthToParent: 0.28),
            Joint(name: "RightHand", parent: "RightForeArm", restLocalPosition: .init(x: 0.16, y: 0, z: 0), boneLengthToParent: 0.16),

            Joint(name: "neck", parent: "Spine", restLocalPosition: .init(x: 0, y: 0.16, z: 0), boneLengthToParent: 0.16),
            Joint(name: "Head", parent: "neck", restLocalPosition: .init(x: 0, y: 0.16, z: 0), boneLengthToParent: 0.16),
            Joint(name: "head_end", parent: "Head", restLocalPosition: .init(x: 0, y: 0.10, z: 0), boneLengthToParent: 0.10),
            Joint(name: "headfront", parent: "Head", restLocalPosition: .init(x: 0, y: 0.02, z: 0.10), boneLengthToParent: 0.10)
        ]
    )
}
