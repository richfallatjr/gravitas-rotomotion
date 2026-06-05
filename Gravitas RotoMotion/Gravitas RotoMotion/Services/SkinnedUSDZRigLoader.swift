import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

enum SkinnedUSDZRigLoader {
    static func load(
        url: URL,
        originalSourceURL: URL? = nil,
        unitScaleToMeters: Float = 0.01,
        sceneUnitsPerMeter: Float = 5.0,
        yawCorrectionRadians: Float = .pi,
        defaultRigZ: Float = -2.0
    ) throws -> SkinnedRigSession {
        let convertToYUp = false
        let scene = try SCNScene(
            url: url,
            options: [
                SCNSceneSource.LoadingOption.convertToYUp: convertToYUp,
                SCNSceneSource.LoadingOption.convertUnitsToMeters: false
            ]
        )

        removeAllAnimationsRecursively(scene.rootNode)

        let placementNode = SCNNode()
        placementNode.name = "ReferenceRigPlacementNode"
        placementNode.isPaused = true

        let correctionNode = SCNNode()
        correctionNode.name = "ReferenceRigCorrectionNode"
        correctionNode.simdEulerAngles = SIMD3<Float>(0, yawCorrectionRadians, 0)
        correctionNode.isPaused = true

        let importedRigRoot = SCNNode()
        importedRigRoot.name = "ReferenceRigImportedRoot"
        importedRigRoot.isPaused = true

        placementNode.addChildNode(correctionNode)
        correctionNode.addChildNode(importedRigRoot)

        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            importedRigRoot.addChildNode(child)
        }

        guard let skinnerInfo = findFirstSkinner(in: importedRigRoot) else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 10001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                    """
                    No SCNSkinner found after loading USDZ.

                    A real posed skinned viewport requires a skinned mesh exposing SCNSkinner bones.
                    """
                ]
            )
        }

        let skinner = skinnerInfo.skinner
        let meshNode = skinnerInfo.node

        if let skeleton = skinner.skeleton {
            removeAllAnimationsRecursively(skeleton)
            skeleton.isPaused = true
        }

        for bone in skinner.bones {
            removeAllAnimationsRecursively(bone)
        }

        var bonesByCanonicalName: [String: SCNNode] = [:]
        var restLocalTransforms: [String: simd_float4x4] = [:]
        var restLocalPositions: [String: SIMD3<Float>] = [:]
        var restLocalOrientations: [String: simd_quatf] = [:]
        var restLocalScales: [String: SIMD3<Float>] = [:]

        for bone in skinner.bones {
            guard let rawName = bone.name else {
                continue
            }

            let leaf = canonicalLeafName(rawName)

            if CanonicalRig.jointNames.contains(leaf) {
                bonesByCanonicalName[leaf] = bone
                restLocalTransforms[leaf] = bone.simdTransform
                restLocalPositions[leaf] = bone.simdPosition
                restLocalOrientations[leaf] = bone.simdOrientation
                restLocalScales[leaf] = bone.simdScale
            }
        }

        guard !bonesByCanonicalName.isEmpty else {
            let boneNames = skinner.bones.compactMap(\.name).sorted()

            throw NSError(
                domain: "GravitasRotoMotion",
                code: 10002,
                userInfo: [
                    NSLocalizedDescriptionKey:
                    """
                    SCNSkinner found, but no bones matched CanonicalRig joint names.
                    Check bone names / prefixes.

                    First bones:
                    \(boneNames.prefix(24).joined(separator: ", "))
                    """
                ]
            )
        }

        let unitScaleMetadata = unitScaleToMeters * sceneUnitsPerMeter
        placementNode.simdScale = SIMD3<Float>(repeating: 1.0)
        placementNode.simdPosition = SIMD3<Float>(0, 0, defaultRigZ)
        placementNode.simdEulerAngles = SIMD3<Float>(0, 0, 0)

        var restWorldPositions: [String: SIMD3<Float>] = [:]

        for joint in CanonicalRig.jointNames {
            if let bone = bonesByCanonicalName[joint] {
                restWorldPositions[joint] = bone.simdWorldPosition
            }
        }

        let restKneePoles: [String: SIMD3<Float>] = [
            "Left": computeRestKneePole(
                hip: restWorldPositions["LeftUpLeg"],
                knee: restWorldPositions["LeftLeg"],
                ankle: restWorldPositions["LeftFoot"]
            ),
            "Right": computeRestKneePole(
                hip: restWorldPositions["RightUpLeg"],
                knee: restWorldPositions["RightLeg"],
                ankle: restWorldPositions["RightFoot"]
            )
        ].compactMapValues { $0 }

        for joint in CanonicalRig.jointNames {
            let boneName = bonesByCanonicalName[joint]?.name ?? "MISSING"
            print("[SkinnedUSDZRigLoader] canonical \(joint) -> SCN bone \(boneName)")
        }

        return SkinnedRigSession(
            sourceURL: url,
            originalSourceURL: originalSourceURL ?? url,
            loadedWithConvertToYUp: convertToYUp,
            displayRootNode: placementNode,
            correctionNode: correctionNode,
            importedRigRootNode: importedRigRoot,
            skinner: skinner,
            skinnedMeshNode: meshNode,
            skeletonRootNode: skinner.skeleton,
            bonesByCanonicalName: bonesByCanonicalName,
            restLocalTransforms: restLocalTransforms,
            restLocalPositions: restLocalPositions,
            restLocalOrientations: restLocalOrientations,
            restLocalScales: restLocalScales,
            restWorldPositions: restWorldPositions,
            restKneePoles: restKneePoles,
            jointOrder: CanonicalRig.jointNames.filter { bonesByCanonicalName[$0] != nil },
            unitScaleMetadata: unitScaleMetadata
        )
    }

    private static func computeRestKneePole(
        hip: SIMD3<Float>?,
        knee: SIMD3<Float>?,
        ankle: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let hip,
              let knee,
              let ankle else {
            return nil
        }

        let hipToAnkle = normalizeSafe(
            ankle - hip,
            fallback: SIMD3<Float>(0, -1, 0)
        )
        let projected = hip + hipToAnkle * simd_dot(knee - hip, hipToAnkle)
        let bend = knee - projected

        return normalizeSafe(
            bend,
            fallback: SIMD3<Float>(0, 0, 1)
        )
    }

    private static func findFirstSkinner(
        in root: SCNNode
    ) -> (node: SCNNode, skinner: SCNSkinner)? {
        if let skinner = root.skinner {
            return (root, skinner)
        }

        for child in root.childNodes {
            if let found = findFirstSkinner(in: child) {
                return found
            }
        }

        return nil
    }

    private static func removeAllAnimationsRecursively(_ node: SCNNode) {
        for key in node.animationKeys {
            node.removeAnimation(forKey: key)
        }

        node.removeAllActions()
        node.isPaused = true

        for child in node.childNodes {
            removeAllAnimationsRecursively(child)
        }
    }

    private static func canonicalLeafName(_ name: String) -> String {
        var result = name

        if result.contains("/") {
            result = String(result.split(separator: "/").last ?? Substring(result))
        }

        if result.contains(":") {
            result = String(result.split(separator: ":").last ?? Substring(result))
        }

        result = result.replacingOccurrences(of: "mixamorig:", with: "")

        return result
    }

    private static func normalizeSafe(
        _ v: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(v)
        guard length > 0.000001 else {
            return fallback
        }

        return v / length
    }
}
