import AppKit
import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO

enum USDZRigSceneLoader {
    private static let skeletonMarkerPrefix = "GravitasImportedRigJointMarker_"

    static func loadRigScene(
        from url: URL,
        defaultOpacity: CGFloat = 0.5
    ) throws -> ImportedRigScene {
        let scene: SCNScene

        do {
            scene = try SCNScene(url: url, options: nil)
        } catch {
            let asset = MDLAsset(url: url)
            scene = SCNScene(mdlAsset: asset)
        }

        let root = scene.rootNode
        applyTransparency(rootNode: root, opacity: defaultOpacity)

        let allNames = collectNodeNames(root)
        let jointNames = inferJointNames(from: root)
        let validation = validateImportedRig(
            jointNames: jointNames,
            allNodeNames: allNames
        )
        let measuredProfile = buildMeasuredRigProfile(
            sourceURL: url,
            root: root,
            jointNames: jointNames
        )

        return ImportedRigScene(
            sourceURL: url,
            scene: scene,
            rootNode: root,
            skeletonJointNames: jointNames,
            validation: validation,
            measuredRigProfile: measuredProfile
        )
    }

    static func applyTransparency(
        rootNode: SCNNode,
        opacity: CGFloat
    ) {
        let clamped = max(0.0, min(opacity, 1.0))

        enumerateIncludingRoot(rootNode) { node in
            guard let geometry = node.geometry else { return }

            for material in geometry.materials {
                material.transparency = clamped
                material.blendMode = .alpha
                material.isDoubleSided = true
                material.writesToDepthBuffer = true
                material.readsFromDepthBuffer = true
            }
        }
    }

    static func setModelVisibility(
        rootNode: SCNNode,
        visible: Bool
    ) {
        enumerateIncludingRoot(rootNode) { node in
            guard node.geometry != nil else { return }
            guard !(node.name ?? "").hasPrefix(skeletonMarkerPrefix) else { return }
            node.isHidden = !visible
        }
    }

    static func setSkeletonMarkers(
        rootNode: SCNNode,
        skeletonJointNames: [String],
        visible: Bool
    ) {
        let jointSet = Set(skeletonJointNames)

        rootNode.enumerateChildNodes { node, _ in
            guard let nodeName = node.name else { return }
            guard jointSet.contains(leafName(nodeName)) else { return }

            let markerName = skeletonMarkerPrefix + leafName(nodeName)
            let marker = node.childNode(withName: markerName, recursively: false) ?? makeJointMarker(name: markerName)

            if marker.parent == nil {
                node.addChildNode(marker)
            }

            marker.isHidden = !visible
        }
    }

    private static func collectNodeNames(_ root: SCNNode) -> [String] {
        var names: [String] = []

        enumerateIncludingRoot(root) { node in
            if let name = node.name, !name.isEmpty {
                names.append(name)
            }
        }

        return names.sorted()
    }

    private static func inferJointNames(from root: SCNNode) -> [String] {
        var matched = Set<String>()

        enumerateIncludingRoot(root) { node in
            guard let nodeName = node.name else { return }

            let leaf = leafName(nodeName)
            if CanonicalRig.jointNames.contains(leaf) {
                matched.insert(leaf)
            }
        }

        return Array(matched).sorted()
    }

    private static func leafName(_ name: String) -> String {
        let pathLeaf: String

        if name.contains("/") {
            pathLeaf = name.split(separator: "/").last.map(String.init) ?? name
        } else {
            pathLeaf = name
        }

        if pathLeaf.contains(":") {
            return pathLeaf.split(separator: ":").last.map(String.init) ?? pathLeaf
        }

        return pathLeaf
    }

    private static func validateImportedRig(
        jointNames: [String],
        allNodeNames: [String]
    ) -> RigValidationReport {
        let imported = Set(jointNames)
        let canonical = Set(CanonicalRig.jointNames)
        let required = Set(CanonicalRig.requiredLandmarks)

        let missingRequired = required
            .filter { !imported.contains($0) }
            .sorted()

        let missingCanonical = canonical
            .filter { !imported.contains($0) }
            .sorted()

        let extra = imported
            .filter { !canonical.contains($0) }
            .sorted()

        return RigValidationReport(
            valid: missingRequired.isEmpty,
            missingRequiredJoints: missingRequired,
            missingCanonicalJoints: missingCanonical,
            extraJoints: extra,
            allImportedNodeNames: allNodeNames
        )
    }

    private static func buildMeasuredRigProfile(
        sourceURL: URL,
        root: SCNNode,
        jointNames: [String]
    ) -> RigProfile? {
        guard !jointNames.isEmpty else { return nil }

        let jointSet = Set(jointNames)
        var nodeByJoint: [String: SCNNode] = [:]

        enumerateIncludingRoot(root) { node in
            guard let nodeName = node.name else { return }

            let leaf = leafName(nodeName)
            guard jointSet.contains(leaf), nodeByJoint[leaf] == nil else { return }
            nodeByJoint[leaf] = node
        }

        let joints = CanonicalRig.jointNames.compactMap { jointName -> RigProfile.Joint? in
            guard let node = nodeByJoint[jointName] else { return nil }

            let parentName = CanonicalRig.parentByJoint[jointName] ?? nil
            let parentNode = parentName.flatMap { nodeByJoint[$0] }
            let origin = SCNVector3(0, 0, 0)
            let boneLength = parentNode.map {
                distance(node.convertPosition(origin, to: nil), $0.convertPosition(origin, to: nil))
            } ?? 0.0

            return RigProfile.Joint(
                name: jointName,
                parent: parentName,
                restLocalTranslation: SIMD3Codable(
                    x: Double(node.position.x),
                    y: Double(node.position.y),
                    z: Double(node.position.z)
                ),
                restLocalRotationWXYZ: SIMD4Codable(
                    w: 1.0,
                    x: 0.0,
                    y: 0.0,
                    z: 0.0
                ),
                boneLengthToParent: boneLength
            )
        }

        guard !joints.isEmpty else { return nil }

        return RigProfile(
            schema: "com.gravitas.rotomotion.rig_profile.from_usd_scene.v0",
            rigID: CanonicalRig.rigID,
            rigVersion: CanonicalRig.rigVersion,
            sourceRigPath: sourceURL.path,
            upAxis: CanonicalRig.upAxis,
            forwardAxis: "Y",
            joints: joints
        )
    }

    private static func enumerateIncludingRoot(
        _ root: SCNNode,
        _ body: (SCNNode) -> Void
    ) {
        body(root)
        root.enumerateChildNodes { node, _ in
            body(node)
        }
    }

    private static func makeJointMarker(name: String) -> SCNNode {
        let sphere = SCNSphere(radius: 0.025)
        sphere.segmentCount = 12

        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemGreen
        material.emission.contents = NSColor.systemGreen
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.name = name
        return node
    }

    private static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        let dz = Double(a.z - b.z)
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}
