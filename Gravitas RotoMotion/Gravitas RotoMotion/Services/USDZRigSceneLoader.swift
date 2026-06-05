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
        print("[RotoMotion RigLoader] Loading \(url.path)")

        let scene = try loadBestScene(from: url)
        let root = scene.rootNode
        let geometryCount = countGeometryNodes(root)

        guard geometryCount > 0 else {
            let allNames = collectNodeNames(root)

            throw NSError(
                domain: "GravitasRotoMotion",
                code: 4203,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                        USDZ loaded but contains no displayable SceneKit geometry.
                        Node count: \(allNames.count)
                        Node names: \(allNames.prefix(12).joined(separator: ", "))
                        This file may be skeleton-only, unsupported USDZ content, or SceneKit cannot read the geometry.
                        """
                ]
            )
        }

        applyTransparency(rootNode: root, opacity: defaultOpacity)
        normalizeSceneForPreview(root)

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

        print(
            """
            [RotoMotion RigLoader] Scene loaded
              nodes: \(allNames.count)
              geometries: \(geometryCount)
              matchedCanonicalJoints: \(jointNames.count)
              missingRequired: \(validation.missingRequiredJoints.joined(separator: ", "))
            """
        )

        return ImportedRigScene(
            sourceURL: url,
            scene: scene,
            rootNode: root,
            skeletonJointNames: jointNames,
            geometryNodeCount: geometryCount,
            validation: validation,
            measuredRigProfile: measuredProfile
        )
    }

    private static func loadBestScene(from url: URL) throws -> SCNScene {
        var errors: [String] = []

        do {
            let scene = try SCNScene(
                url: url,
                options: [
                    SCNSceneSource.LoadingOption.convertToYUp: false,
                    SCNSceneSource.LoadingOption.convertUnitsToMeters: false
                ]
            )

            let geometryCount = countGeometryNodes(scene.rootNode)

            if geometryCount > 0 {
                print("[RotoMotion RigLoader] Loaded with SCNScene(url:), geometries=\(geometryCount)")
                return scene
            }

            errors.append("SCNScene(url:) loaded zero geometries.")
        } catch {
            errors.append("SCNScene(url:) failed: \(error.localizedDescription)")
        }

        do {
            guard let source = SCNSceneSource(url: url, options: nil),
                  let scene = source.scene(options: nil) else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 4201,
                    userInfo: [
                        NSLocalizedDescriptionKey: "SCNSceneSource returned nil scene."
                    ]
                )
            }

            let geometryCount = countGeometryNodes(scene.rootNode)

            if geometryCount > 0 {
                print("[RotoMotion RigLoader] Loaded with SCNSceneSource, geometries=\(geometryCount)")
                return scene
            }

            errors.append("SCNSceneSource loaded zero geometries.")
        } catch {
            errors.append("SCNSceneSource failed: \(error.localizedDescription)")
        }

        let asset = MDLAsset(url: url)
        let scene = SCNScene(mdlAsset: asset)

        let geometryCount = countGeometryNodes(scene.rootNode)

        if geometryCount > 0 {
            print("[RotoMotion RigLoader] Loaded with ModelIO MDLAsset, geometries=\(geometryCount)")
            return scene
        }

        errors.append("ModelIO loaded zero geometries.")

        throw NSError(
            domain: "GravitasRotoMotion",
            code: 4202,
            userInfo: [
                NSLocalizedDescriptionKey:
                    """
                    All rig load paths failed or returned no displayable geometry.
                    \(errors.joined(separator: "\n"))
                    """
            ]
        )
    }

    private static func countGeometryNodes(_ root: SCNNode) -> Int {
        var count = 0

        enumerateIncludingRoot(root) { node in
            if node.geometry != nil {
                count += 1
            }
        }

        return count
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

            for candidate in nameCandidates(nodeName) {
                if CanonicalRig.jointNames.contains(candidate) {
                    matched.insert(candidate)
                }
            }
        }

        return Array(matched).sorted()
    }

    private static func nameCandidates(_ name: String) -> [String] {
        var candidates = [name]

        if let last = name.split(separator: "/").last {
            candidates.append(String(last))
        }

        if let last = name.split(separator: ":").last {
            candidates.append(String(last))
        }

        candidates.append(name.replacingOccurrences(of: "mixamorig:", with: ""))
        candidates.append(name.replacingOccurrences(of: "Armature|", with: ""))

        return Array(Set(candidates))
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

            for candidate in nameCandidates(nodeName) where jointSet.contains(candidate) {
                guard nodeByJoint[candidate] == nil else { continue }
                nodeByJoint[candidate] = node
            }
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
                restLocalRotationEulerXYZ: SIMD3Codable(
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

    private static func normalizeSceneForPreview(_ root: SCNNode) {
        let (minBounds, maxBounds) = root.boundingBox

        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )
        let maxDimension = max(size.x, max(size.y, size.z))

        guard maxDimension.isFinite, maxDimension > 0 else {
            return
        }

        let targetHeight: CGFloat = 2.0
        let scale = targetHeight / maxDimension

        if scale.isFinite, scale > 0 {
            root.scale = SCNVector3(scale, scale, scale)
        }

        let center = SCNVector3(
            (minBounds.x + maxBounds.x) * 0.5,
            (minBounds.y + maxBounds.y) * 0.5,
            (minBounds.z + maxBounds.z) * 0.5
        )

        root.position = SCNVector3(
            -center.x * root.scale.x,
            -center.y * root.scale.y,
            -center.z * root.scale.z
        )
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
