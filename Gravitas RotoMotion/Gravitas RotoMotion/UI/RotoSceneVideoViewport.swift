import AppKit
import SceneKit
import SwiftUI
import simd

struct RotoSceneVideoViewport: NSViewRepresentable {
    let image: NSImage?
    let frameIndex: Int

    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?

    let groundPlane: GroundPlaneController?
    let raySolveResult: RotoRaySolveResult?
    let raySolvedFrame: RotoRayAnimationSolveResult.Frame?

    let showRawVision: Bool
    let showNormalizedMeshy: Bool
    let showSmoothedMeshy: Bool
    let showGroundPlane: Bool
    let showVisionRays: Bool
    let showRaySolvedRig: Bool
    let onVideoPlaneSizeChanged: ((CGSize) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onVideoPlaneSizeChanged = onVideoPlaneSizeChanged
        context.coordinator.update(
            view: view,
            image: image,
            frameIndex: frameIndex,
            rawFrame: rawFrame,
            normalizedFrame: normalizedFrame,
            smoothedFrame: smoothedFrame,
            groundPlane: groundPlane,
            raySolveResult: raySolveResult,
            raySolvedFrame: raySolvedFrame,
            showRawVision: showRawVision,
            showNormalizedMeshy: showNormalizedMeshy,
            showSmoothedMeshy: showSmoothedMeshy,
            showGroundPlane: showGroundPlane,
            showVisionRays: showVisionRays,
            showRaySolvedRig: showRaySolvedRig
        )
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let videoPlaneNode = SCNNode()
        private let rawOverlayRoot = SCNNode()
        private let normalizedOverlayRoot = SCNNode()
        private let smoothedOverlayRoot = SCNNode()
        private let groundRoot = SCNNode()
        private let visionRayRoot = SCNNode()
        private let solvedRigRoot = SCNNode()
        private let solveErrorRoot = SCNNode()

        var onVideoPlaneSizeChanged: ((CGSize) -> Void)?

        private var lastImageToken = -1
        private var lastImageObjectID: ObjectIdentifier?
        private var videoPlaneSize = CGSize(width: 9.0, height: 16.0)
        private let cameraPadding: CGFloat = 1.02
        private var lastViewBounds: CGRect = .zero
        private var lastVideoPlaneSize: CGSize = .zero

        func makeView() -> SCNView {
            let view = SCNView()

            view.scene = scene
            view.backgroundColor = .black
            view.allowsCameraControl = false
            view.autoenablesDefaultLighting = false
            view.rendersContinuously = true
            view.antialiasingMode = .multisampling4X
            view.isPlaying = true

            setupScene()

            print("[RotoSceneVideoViewport] makeView created real SCNView viewport")

            return view
        }

        private func setupScene() {
            scene.background.contents = NSColor.black

            cameraNode.name = "RotoMotionLockedOrthographicCamera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.usesOrthographicProjection = true
            cameraNode.camera?.orthographicScale = 16.0
            cameraNode.position = SCNVector3(0, 0, 10)
            cameraNode.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(cameraNode)

            videoPlaneNode.name = "RotoMotionVideoUVCard"
            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: 9.0,
                height: 16.0,
                image: nil
            )
            videoPlaneNode.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(videoPlaneNode)

            rawOverlayRoot.name = "RawVisionOverlayRoot"
            normalizedOverlayRoot.name = "NormalizedMeshyOverlayRoot"
            smoothedOverlayRoot.name = "SmoothedMeshyOverlayRoot"
            groundRoot.name = "GroundPlaneRoot"
            visionRayRoot.name = "VisionRayRoot"
            solvedRigRoot.name = "RaySolvedRigRoot"
            solveErrorRoot.name = "RaySolveErrorRoot"

            scene.rootNode.addChildNode(groundRoot)
            scene.rootNode.addChildNode(rawOverlayRoot)
            scene.rootNode.addChildNode(normalizedOverlayRoot)
            scene.rootNode.addChildNode(smoothedOverlayRoot)
            scene.rootNode.addChildNode(visionRayRoot)
            scene.rootNode.addChildNode(solvedRigRoot)
            scene.rootNode.addChildNode(solveErrorRoot)

            groundRoot.addChildNode(makeGroundPlaneNode())
        }

        func update(
            view: SCNView,
            image: NSImage?,
            frameIndex: Int,
            rawFrame: RawVisionPoseCapture.PoseFrame?,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            smoothedFrame: SmoothedMeshyPoseCapture.Frame?,
            groundPlane: GroundPlaneController?,
            raySolveResult: RotoRaySolveResult?,
            raySolvedFrame: RotoRayAnimationSolveResult.Frame?,
            showRawVision: Bool,
            showNormalizedMeshy: Bool,
            showSmoothedMeshy: Bool,
            showGroundPlane: Bool,
            showVisionRays: Bool,
            showRaySolvedRig: Bool
        ) {
            view.allowsCameraControl = false
            view.pointOfView = cameraNode

            if let image {
                updateVideoPlaneIfNeeded(
                    image: image,
                    frameIndex: frameIndex
                )
            } else {
                clearVideoPlaneIfNeeded()
            }

            updateCameraToFrameVideoCard(viewBounds: view.bounds)
            updateGroundPlane(groundPlane: groundPlane, visible: showGroundPlane)
            updateRawOverlay(rawFrame, visible: showRawVision)
            updateNormalizedOverlay(normalizedFrame, visible: showNormalizedMeshy)
            updateSmoothedOverlay(smoothedFrame, visible: showSmoothedMeshy)
            updateRaySolveDebug(
                result: raySolveResult,
                raySolvedFrame: raySolvedFrame,
                showRays: showVisionRays,
                showSolvedRig: showRaySolvedRig
            )
        }

        private func updateVideoPlaneIfNeeded(
            image: NSImage,
            frameIndex: Int
        ) {
            let imageObjectID = ObjectIdentifier(image)

            guard frameIndex != lastImageToken || imageObjectID != lastImageObjectID else {
                return
            }

            lastImageToken = frameIndex
            lastImageObjectID = imageObjectID

            let width = max(image.size.width, 1)
            let height = max(image.size.height, 1)
            let aspect = width / height

            let planeHeight: CGFloat = 16.0
            let planeWidth = planeHeight * aspect

            videoPlaneSize = CGSize(width: planeWidth, height: planeHeight)
            onVideoPlaneSizeChanged?(videoPlaneSize)

            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: planeWidth,
                height: planeHeight,
                image: image
            )

            lastVideoPlaneSize = .zero

            print(
                """
                [RotoSceneVideoViewport] Updated UV video card
                  frame: \(frameIndex)
                  imageSize: \(image.size)
                  planeSize: \(videoPlaneSize)
                """
            )
        }

        private func clearVideoPlaneIfNeeded() {
            guard lastImageToken != -1 || lastImageObjectID != nil else {
                return
            }

            lastImageToken = -1
            lastImageObjectID = nil
            videoPlaneSize = CGSize(width: 9.0, height: 16.0)
            onVideoPlaneSizeChanged?(videoPlaneSize)
            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: videoPlaneSize.width,
                height: videoPlaneSize.height,
                image: nil
            )
            lastVideoPlaneSize = .zero
        }

        private func makeVideoPlaneGeometry(
            width: CGFloat,
            height: CGFloat,
            image: NSImage?
        ) -> SCNGeometry {
            let plane = SCNPlane(width: width, height: height)

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image ?? NSColor.black
            material.diffuse.magnificationFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.mipFilter = .linear
            material.isDoubleSided = true
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true

            plane.materials = [material]
            return plane
        }

        private func updateCameraToFrameVideoCard(viewBounds: CGRect) {
            let boundsChanged =
                abs(viewBounds.width - lastViewBounds.width) > 0.5 ||
                abs(viewBounds.height - lastViewBounds.height) > 0.5

            let planeChanged =
                abs(videoPlaneSize.width - lastVideoPlaneSize.width) > 0.0001 ||
                abs(videoPlaneSize.height - lastVideoPlaneSize.height) > 0.0001

            guard boundsChanged || planeChanged else {
                return
            }

            lastViewBounds = viewBounds
            lastVideoPlaneSize = videoPlaneSize

            frameVideoCardToCamera(
                viewBounds: viewBounds,
                reason: boundsChanged && planeChanged
                    ? "bounds+plane changed"
                    : boundsChanged
                        ? "bounds changed"
                        : "plane changed"
            )
        }

        private func frameVideoCardToCamera(
            viewBounds: CGRect,
            reason: String
        ) {
            guard let camera = cameraNode.camera else {
                return
            }

            let viewportWidth = max(viewBounds.width, 1.0)
            let viewportHeight = max(viewBounds.height, 1.0)
            let viewportAspect = viewportWidth / viewportHeight

            let planeWidth = max(videoPlaneSize.width, 0.0001)
            let planeHeight = max(videoPlaneSize.height, 0.0001)

            let requiredVerticalForHeight = planeHeight
            let requiredVerticalForWidth = planeWidth / viewportAspect

            let requiredVerticalScale = max(
                requiredVerticalForHeight,
                requiredVerticalForWidth
            ) * cameraPadding

            camera.usesOrthographicProjection = true
            camera.orthographicScale = requiredVerticalScale

            cameraNode.position = SCNVector3(0, 0, 10)
            cameraNode.look(at: SCNVector3(0, 0, 0))

            print(
                """
                [RotoSceneVideoViewport] Frame Card
                  reason: \(reason)
                  viewBounds: \(Int(viewportWidth))x\(Int(viewportHeight))
                  viewportAspect: \(String(format: "%.4f", viewportAspect))
                  planeSize: \(String(format: "%.4f", planeWidth))x\(String(format: "%.4f", planeHeight))
                  requiredVerticalForHeight: \(String(format: "%.4f", requiredVerticalForHeight))
                  requiredVerticalForWidth: \(String(format: "%.4f", requiredVerticalForWidth))
                  padding: \(String(format: "%.3f", cameraPadding))
                  orthographicScale: \(String(format: "%.4f", requiredVerticalScale))
                """
            )
        }

        private func pointOnVideoPlane(
            x: Double,
            y: Double,
            zOffset: Float
        ) -> SCNVector3 {
            let px = (CGFloat(x) - 0.5) * videoPlaneSize.width
            let py = (CGFloat(y) - 0.5) * videoPlaneSize.height

            return SCNVector3(
                Float(px),
                Float(py),
                zOffset
            )
        }

        private func updateRawOverlay(
            _ frame: RawVisionPoseCapture.PoseFrame?,
            visible: Bool
        ) {
            rawOverlayRoot.isHidden = !visible
            removeAllChildren(from: rawOverlayRoot)

            guard visible, let frame else {
                return
            }

            for (_, joint) in frame.joints {
                let node = makePointNode(
                    color: NSColor.orange.withAlphaComponent(
                        CGFloat(max(0.25, min(joint.confidence, 1.0)))
                    ),
                    radius: 0.055
                )
                node.position = pointOnVideoPlane(
                    x: joint.x,
                    y: joint.y,
                    zOffset: 0.035
                )
                rawOverlayRoot.addChildNode(node)
            }
        }

        private func updateNormalizedOverlay(
            _ frame: NormalizedMeshyPoseCapture.Frame?,
            visible: Bool
        ) {
            normalizedOverlayRoot.isHidden = !visible
            removeAllChildren(from: normalizedOverlayRoot)

            guard visible, let frame else {
                return
            }

            addMeshySkeleton(
                joints: frame.joints.mapValues {
                    MeshyOverlayPoint(
                        x: $0.x,
                        y: $0.y,
                        missing: $0.missing,
                        generated: $0.generated
                    )
                },
                root: normalizedOverlayRoot,
                color: NSColor.yellow,
                zOffset: 0.05
            )
        }

        private func updateSmoothedOverlay(
            _ frame: SmoothedMeshyPoseCapture.Frame?,
            visible: Bool
        ) {
            smoothedOverlayRoot.isHidden = !visible
            removeAllChildren(from: smoothedOverlayRoot)

            guard visible, let frame else {
                return
            }

            var points: [String: MeshyOverlayPoint] = [:]

            for (name, joint) in frame.joints {
                points[name] = MeshyOverlayPoint(
                    x: joint.smoothedX,
                    y: joint.smoothedY,
                    missing: joint.missing,
                    generated: joint.generated
                )
            }

            addMeshySkeleton(
                joints: points,
                root: smoothedOverlayRoot,
                color: NSColor.cyan,
                zOffset: 0.065
            )
        }

        private struct MeshyOverlayPoint {
            let x: Double
            let y: Double
            let missing: Bool
            let generated: Bool
        }

        private func addMeshySkeleton(
            joints: [String: MeshyOverlayPoint],
            root: SCNNode,
            color: NSColor,
            zOffset: Float
        ) {
            let bones: [(String, String)] = [
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

            for (a, b) in bones {
                guard let ja = joints[a],
                      let jb = joints[b],
                      !ja.missing,
                      !jb.missing else {
                    continue
                }

                root.addChildNode(
                    makeLineNode(
                        from: pointOnVideoPlane(x: ja.x, y: ja.y, zOffset: zOffset),
                        to: pointOnVideoPlane(x: jb.x, y: jb.y, zOffset: zOffset),
                        color: color.withAlphaComponent(0.85)
                    )
                )
            }

            for (_, joint) in joints where !joint.missing {
                let node = makePointNode(
                    color: joint.generated
                        ? color.withAlphaComponent(0.35)
                        : color,
                    radius: joint.generated ? 0.045 : 0.07
                )
                node.position = pointOnVideoPlane(
                    x: joint.x,
                    y: joint.y,
                    zOffset: zOffset + 0.01
                )
                root.addChildNode(node)
            }
        }

        private func updateRaySolveDebug(
            result: RotoRaySolveResult?,
            raySolvedFrame: RotoRayAnimationSolveResult.Frame?,
            showRays: Bool,
            showSolvedRig: Bool
        ) {
            removeAllChildren(from: visionRayRoot)
            removeAllChildren(from: solvedRigRoot)
            removeAllChildren(from: solveErrorRoot)

            guard let result else {
                visionRayRoot.isHidden = true
                solvedRigRoot.isHidden = !showSolvedRig || raySolvedFrame == nil
                solveErrorRoot.isHidden = true

                if showSolvedRig, let raySolvedFrame {
                    drawSolvedRig(raySolvedFrame)
                }

                return
            }

            visionRayRoot.isHidden = !showRays
            solvedRigRoot.isHidden = !showSolvedRig
            solveErrorRoot.isHidden = !showSolvedRig

            if showRays {
                for (_, ray) in result.rays {
                    visionRayRoot.addChildNode(
                        makeLineNode(
                            from: SCNVector3(ray.origin),
                            to: SCNVector3(ray.end),
                            color: NSColor.systemBlue.withAlphaComponent(0.35)
                        )
                    )
                }
            }

            if showSolvedRig {
                drawSolvedRig(result)
                drawSolveErrors(result)
            }
        }

        private func drawSolvedRig(_ frame: RotoRayAnimationSolveResult.Frame) {
            for (a, b) in solvedRigBones {
                guard let ja = frame.jointPositions[a],
                      let jb = frame.jointPositions[b] else {
                    continue
                }

                solvedRigRoot.addChildNode(
                    makeLineNode(
                        from: SCNVector3(ja),
                        to: SCNVector3(jb),
                        color: NSColor.systemGreen.withAlphaComponent(0.95)
                    )
                )
            }

            for (name, position) in frame.jointPositions {
                let solved = frame.solvedJoints.contains(name)
                let node = makePointNode(
                    color: solved ? NSColor.systemGreen : NSColor.systemRed,
                    radius: solved ? 0.08 : 0.06
                )
                node.position = SCNVector3(position)
                solvedRigRoot.addChildNode(node)
            }
        }

        private func drawSolvedRig(_ result: RotoRaySolveResult) {
            for (a, b) in solvedRigBones {
                guard let ja = result.joints[a],
                      let jb = result.joints[b] else {
                    continue
                }

                solvedRigRoot.addChildNode(
                    makeLineNode(
                        from: SCNVector3(ja.worldPosition),
                        to: SCNVector3(jb.worldPosition),
                        color: NSColor.systemGreen.withAlphaComponent(0.95)
                    )
                )
            }

            for (_, joint) in result.joints {
                let node = makePointNode(
                    color: joint.solved ? NSColor.systemGreen : NSColor.systemRed,
                    radius: joint.solved ? 0.08 : 0.06
                )
                node.position = SCNVector3(joint.worldPosition)
                solvedRigRoot.addChildNode(node)
            }
        }

        private var solvedRigBones: [(String, String)] {
            [
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
                ("RightForeArm", "RightHand"),
                ("Hips", "LeftUpLeg"),
                ("LeftUpLeg", "LeftLeg"),
                ("LeftLeg", "LeftFoot"),
                ("LeftFoot", "LeftToeBase"),
                ("Hips", "RightUpLeg"),
                ("RightUpLeg", "RightLeg"),
                ("RightLeg", "RightFoot"),
                ("RightFoot", "RightToeBase")
            ]
        }

        private func drawSolveErrors(_ result: RotoRaySolveResult) {
            for (jointName, joint) in result.joints {
                guard let ray = result.rays[jointName] else {
                    continue
                }

                let closest = RotoRayRigSolver.closestPointOnRay(
                    to: joint.worldPosition,
                    ray: ray
                )

                guard simd_length(joint.worldPosition - closest) > 0.001 else {
                    continue
                }

                solveErrorRoot.addChildNode(
                    makeLineNode(
                        from: SCNVector3(joint.worldPosition),
                        to: SCNVector3(closest),
                        color: NSColor.systemRed.withAlphaComponent(0.75)
                    )
                )
            }
        }

        private func updateGroundPlane(
            groundPlane: GroundPlaneController?,
            visible: Bool
        ) {
            guard let groundPlane else {
                groundRoot.isHidden = true
                return
            }

            groundRoot.isHidden = !visible || !groundPlane.visible

            groundRoot.position = SCNVector3(
                Float(groundPlane.offsetX) * Float(videoPlaneSize.width) * 0.25,
                Float(groundPlane.offsetY) * Float(videoPlaneSize.height) * 0.25,
                0.08 + Float(groundPlane.groundHeight)
            )

            groundRoot.eulerAngles = SCNVector3(
                Float(groundPlane.tumbleXRadians),
                0,
                Float(groundPlane.rollZRadians)
            )

            groundRoot.scale = SCNVector3(
                Float(groundPlane.size),
                Float(groundPlane.size),
                Float(groundPlane.size)
            )

            groundRoot.childNodes.forEach {
                updateMaterialOpacity(
                    node: $0,
                    opacity: CGFloat(groundPlane.opacity)
                )
            }
        }

        private func makeGroundPlaneNode() -> SCNNode {
            let plane = SCNPlane(width: 2.0, height: 0.9)

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.5)
            material.transparency = 0.5
            material.blendMode = .alpha
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false

            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.name = "RotoMotionGroundPlane"
            return node
        }

        private func makePointNode(
            color: NSColor,
            radius: CGFloat
        ) -> SCNNode {
            let geometry = SCNSphere(radius: radius)
            geometry.segmentCount = 12

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false

            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }

        private func makeLineNode(
            from: SCNVector3,
            to: SCNVector3,
            color: NSColor
        ) -> SCNNode {
            let source = SCNGeometrySource(vertices: [from, to])
            let indices: [Int32] = [0, 1]
            let indexData = indices.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }

            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .line,
                primitiveCount: 1,
                bytesPerIndex: MemoryLayout<Int32>.size
            )

            let geometry = SCNGeometry(
                sources: [source],
                elements: [element]
            )

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false

            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }

        private func updateMaterialOpacity(
            node: SCNNode,
            opacity: CGFloat
        ) {
            node.geometry?.materials.forEach { material in
                material.transparency = opacity
                material.blendMode = .alpha
                material.isDoubleSided = true
            }
        }

        private func removeAllChildren(from node: SCNNode) {
            node.childNodes.forEach { child in
                child.removeFromParentNode()
            }
        }
    }
}

private extension SCNVector3 {
    init(_ value: SIMD3<Float>) {
        self.init(value.x, value.y, value.z)
    }
}
