import Foundation
import SceneKit

struct ImportedRigScene {
    let sourceURL: URL
    let scene: SCNScene
    let rootNode: SCNNode
    let skeletonJointNames: [String]
    let geometryNodeCount: Int
    let validation: RigValidationReport
    let measuredRigProfile: RigProfile?
}

struct RigValidationReport: Equatable {
    let valid: Bool
    let missingRequiredJoints: [String]
    let missingCanonicalJoints: [String]
    let extraJoints: [String]
    let allImportedNodeNames: [String]
}
