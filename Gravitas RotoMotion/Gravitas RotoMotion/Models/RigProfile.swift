import Foundation
import simd

struct RigProfile: Codable {
    let schema: String
    let rigID: String
    let rigVersion: String
    let sourceRigPath: String?
    let upAxis: String
    let forwardAxis: String
    let joints: [Joint]

    struct Joint: Codable, Identifiable {
        var id: String { name }

        let name: String
        let parent: String?
        let restLocalTranslation: SIMD3Codable
        let restLocalRotationEulerXYZ: SIMD3Codable
        let boneLengthToParent: Double
    }

    struct ValidationResult: Codable {
        let valid: Bool
        let missingRequiredJoints: [String]
        let extraJoints: [String]
    }

    var jointByName: [String: Joint] {
        Dictionary(uniqueKeysWithValues: joints.map { ($0.name, $0) })
    }

    func validate() -> ValidationResult {
        let names = Set(joints.map(\.name))
        let required = Set(CanonicalRig.requiredLandmarks)
        let canonical = Set(CanonicalRig.jointNames)

        return ValidationResult(
            valid: required.isSubset(of: names),
            missingRequiredJoints: required.filter { !names.contains($0) }.sorted(),
            extraJoints: names.filter { !canonical.contains($0) }.sorted()
        )
    }
}

struct SIMD3Codable: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    var simdFloat: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}
