import Combine
import Foundation
import SceneKit
import simd

final class SkinnedRigSession: ObservableObject {
    let sourceURL: URL

    /// Normal node that can be added to the RotoMotion viewport scene.
    /// This is not the loaded SCNScene.rootNode.
    let displayRootNode: SCNNode
    let correctionNode: SCNNode
    let importedRigRootNode: SCNNode

    let skinner: SCNSkinner
    let skinnedMeshNode: SCNNode
    let skeletonRootNode: SCNNode?
    let bonesByCanonicalName: [String: SCNNode]

    let restLocalTransforms: [String: simd_float4x4]
    let restLocalPositions: [String: SIMD3<Float>]
    let restLocalOrientations: [String: simd_quatf]
    let restLocalScales: [String: SIMD3<Float>]

    let jointOrder: [String]

    /// Metadata only. Never apply this to displayRootNode.simdScale.
    let unitScaleMetadata: Float

    var validBoneCount: Int {
        bonesByCanonicalName.count
    }

    init(
        sourceURL: URL,
        displayRootNode: SCNNode,
        correctionNode: SCNNode,
        importedRigRootNode: SCNNode,
        skinner: SCNSkinner,
        skinnedMeshNode: SCNNode,
        skeletonRootNode: SCNNode?,
        bonesByCanonicalName: [String: SCNNode],
        restLocalTransforms: [String: simd_float4x4],
        restLocalPositions: [String: SIMD3<Float>],
        restLocalOrientations: [String: simd_quatf],
        restLocalScales: [String: SIMD3<Float>],
        jointOrder: [String],
        unitScaleMetadata: Float
    ) {
        self.sourceURL = sourceURL
        self.displayRootNode = displayRootNode
        self.correctionNode = correctionNode
        self.importedRigRootNode = importedRigRootNode
        self.skinner = skinner
        self.skinnedMeshNode = skinnedMeshNode
        self.skeletonRootNode = skeletonRootNode
        self.bonesByCanonicalName = bonesByCanonicalName
        self.restLocalTransforms = restLocalTransforms
        self.restLocalPositions = restLocalPositions
        self.restLocalOrientations = restLocalOrientations
        self.restLocalScales = restLocalScales
        self.jointOrder = jointOrder
        self.unitScaleMetadata = unitScaleMetadata
    }
}
