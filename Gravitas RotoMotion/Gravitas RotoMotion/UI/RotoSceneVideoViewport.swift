import AppKit
import SceneKit
import SwiftUI
import simd

final class RotoSCNView: SCNView {
    var onMouseDownInView: ((NSEvent, RotoSCNView) -> Bool)?
    var onMouseDraggedInView: ((NSEvent, RotoSCNView) -> Void)?
    var onMouseUpInView: ((NSEvent, RotoSCNView) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if onMouseDownInView?(event, self) == true {
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let onMouseDraggedInView {
            onMouseDraggedInView(event, self)
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let onMouseUpInView {
            onMouseUpInView(event, self)
            return
        }

        super.mouseUp(with: event)
    }
}

private enum ReferenceRigMaterialOverlay {
    private static let materialNamePrefix = "RotoMotionReferenceOverlay"

    static func applyHalfOpacity(to root: SCNNode, opacity: CGFloat = 0.5) {
        visit(root) { node in
            guard let geometry = node.geometry else {
                return
            }

            var materials: [SCNMaterial] = []
            materials.reserveCapacity(geometry.materials.count)

            for material in geometry.materials {
                let overlayMaterial: SCNMaterial

                if material.name?.hasPrefix(materialNamePrefix) == true {
                    overlayMaterial = material
                } else {
                    overlayMaterial = material.copy() as! SCNMaterial
                    overlayMaterial.name = "\(materialNamePrefix):\(material.name ?? "material")"
                }

                overlayMaterial.transparency = opacity
                overlayMaterial.blendMode = .alpha
                overlayMaterial.writesToDepthBuffer = false
                overlayMaterial.readsFromDepthBuffer = true
                overlayMaterial.isDoubleSided = true
                overlayMaterial.transparencyMode = .dualLayer

                materials.append(overlayMaterial)
            }

            geometry.materials = materials
            node.opacity = 1.0
            node.isHidden = false
            node.renderingOrder = 100
        }
    }

    private static func visit(_ node: SCNNode, _ body: (SCNNode) -> Void) {
        body(node)

        for child in node.childNodes {
            visit(child, body)
        }
    }
}

struct RotoSceneVideoViewport: NSViewRepresentable {
    let image: NSImage?
    let frameIndex: Int

    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let stereoJointFrame: StereoMeshyJointCapture.Frame?

    let groundPlane: GroundPlaneController?
    let raySolveResult: RotoRaySolveResult?
    let raySolvedFrame: RotoRayAnimationSolveResult.Frame?
    let skinnedRigSession: SkinnedRigSession?
    let cameraFOVDegrees: Double
    let cameraProfileName: String
    let currentVideoPlaneZ: Float
    let referenceRigScaleMultiplier: Double
    let referenceRigX: Double
    let referenceRigY: Double
    let referenceRigZ: Double
    let referenceRigYawDegrees: Double
    let applySolvedPoseToReferenceRig: Bool
    let rigRotationApplyMode: RigRotationApplyMode
    let rotationOverrideLayer: JointRotationOverrideLayer
    let heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>]
    let liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>]
    let liveRotationOverridesActive: Bool
    let rotationOverrideRevision: Int

    let showRawVision: Bool
    let showNormalizedMeshy: Bool
    let showSmoothedMeshy: Bool
    let showStereoJointDepth: Bool
    let showGroundPlane: Bool
    let showVisionRays: Bool
    let showRaySolvedRig: Bool
    let showSkinnedRig: Bool
    let showRotationGizmo: Bool
    let stereoSceneUnitsPerMeter: Double
    let rotationGizmoSpace: RotationGizmoSpace
    let selectedRotationJoint: String
    let onRotationGizmoEulerChanged: (_ joint: String, _ eulerXYZ: SIMD3<Float>) -> Void
    let onRotationGizmoStatus: (_ status: String) -> Void
    let onRotationGizmoDragEnded: (() -> Void)?
    let onVideoPlaneSizeChanged: ((CGSize) -> Void)?
    let onReferenceRigVisibilityStatusChanged: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onRotationGizmoEulerChanged = onRotationGizmoEulerChanged
        context.coordinator.onRotationGizmoStatus = onRotationGizmoStatus
        context.coordinator.onRotationGizmoDragEnded = onRotationGizmoDragEnded
        context.coordinator.onVideoPlaneSizeChanged = onVideoPlaneSizeChanged
        context.coordinator.onReferenceRigVisibilityStatusChanged = onReferenceRigVisibilityStatusChanged
        context.coordinator.update(
            view: view,
            image: image,
            frameIndex: frameIndex,
            rawFrame: rawFrame,
            normalizedFrame: normalizedFrame,
            smoothedFrame: smoothedFrame,
            stereoJointFrame: stereoJointFrame,
            groundPlane: groundPlane,
            raySolveResult: raySolveResult,
            raySolvedFrame: raySolvedFrame,
            skinnedRigSession: skinnedRigSession,
            cameraFOVDegrees: cameraFOVDegrees,
            cameraProfileName: cameraProfileName,
            currentVideoPlaneZ: currentVideoPlaneZ,
            referenceRigScaleMultiplier: referenceRigScaleMultiplier,
            referenceRigX: referenceRigX,
            referenceRigY: referenceRigY,
            referenceRigZ: referenceRigZ,
            referenceRigYawDegrees: referenceRigYawDegrees,
            applySolvedPoseToReferenceRig: applySolvedPoseToReferenceRig,
            rigRotationApplyMode: rigRotationApplyMode,
            rotationOverrideLayer: rotationOverrideLayer,
            heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
            liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
            liveRotationOverridesActive: liveRotationOverridesActive,
            rotationOverrideRevision: rotationOverrideRevision,
            showRawVision: showRawVision,
            showNormalizedMeshy: showNormalizedMeshy,
            showSmoothedMeshy: showSmoothedMeshy,
            showStereoJointDepth: showStereoJointDepth,
            showGroundPlane: showGroundPlane,
            showVisionRays: showVisionRays,
            showRaySolvedRig: showRaySolvedRig,
            showSkinnedRig: showSkinnedRig,
            showRotationGizmo: showRotationGizmo,
            stereoSceneUnitsPerMeter: stereoSceneUnitsPerMeter,
            rotationGizmoSpace: rotationGizmoSpace,
            selectedRotationJoint: selectedRotationJoint
        )
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let videoPlaneNode = SCNNode()
        private let rawOverlayRoot = SCNNode()
        private let normalizedOverlayRoot = SCNNode()
        private let smoothedOverlayRoot = SCNNode()
        private let stereoDepthRoot = SCNNode()
        private let groundRoot = SCNNode()
        private let visionRayRoot = SCNNode()
        private let solvedRigRoot = SCNNode()
        private let solveErrorRoot = SCNNode()
        private let rigBoundsRoot = SCNNode()
        private let rotationGizmo = ViewportJointRotationGizmo()

        var onRotationGizmoEulerChanged: ((String, SIMD3<Float>) -> Void)?
        var onRotationGizmoStatus: ((String) -> Void)?
        var onRotationGizmoDragEnded: (() -> Void)?
        var onVideoPlaneSizeChanged: ((CGSize) -> Void)?
        var onReferenceRigVisibilityStatusChanged: ((String) -> Void)?

        private var lastImageToken = -1
        private var lastImageObjectID: ObjectIdentifier?
        private var lastVideoImageSize: CGSize = .zero
        private var videoPlaneSize = CGSize(width: 9.0, height: 16.0)
        private var lastViewBounds: CGRect = .zero
        private var lastVideoPlaneSize: CGSize = .zero
        private var lastVideoPlaneZ: Float = .nan
        private var lastAppliedCameraFOVDegrees: Double = -1
        private var lastVideoPlaneCameraFOVDegrees: Double = -1
        private var currentVideoPlaneZ: Float = -2000.0
        private var currentCameraFOVDegrees: Double = 69.4
        private var currentCameraProfileName = "iPhone 17 Main 1x / 26mm"
        private var didLogDrawnSolvedRigPoseSource = false
        private var currentSkinnedRigURL: URL?
        private var skinnedRigRoot: SCNNode?
        private var lastRigFitSignature: String?
        private var lastReferenceRigPlacementSignature: String?
        private var lastReferenceRigOverlaySignature: String?
        private var lastCurvePinnedPlaybackLogFrame: Int?
        private var selectedRotationJoint = "Head"
        private var currentSkinnedRigSession: SkinnedRigSession?
        private var heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:]
        private var liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:]
        private var activeGizmoAxis: ViewportJointRotationGizmo.Axis?
        private var activeGizmoJoint: String?
        private var activeGizmoPivotWorld: SIMD3<Float>?
        private var activeGizmoAxisWorld: SIMD3<Float>?
        private var activeGizmoStartVectorWorld: SIMD3<Float>?
        private var activeGizmoStartEuler: SIMD3<Float>?
        private var showRotationGizmo = false
        private var lastRotationGizmoVisibilitySignature: String?
        private var lastRotationOverrideLogSignature: String?

        func makeView() -> SCNView {
            let view = RotoSCNView()

            view.scene = scene
            view.backgroundColor = .black
            view.allowsCameraControl = false
            view.autoenablesDefaultLighting = false
            view.rendersContinuously = true
            view.antialiasingMode = .multisampling4X
            view.isPlaying = true

            setupScene()

            view.onMouseDownInView = { [weak self] event, view in
                self?.handleMouseDown(event: event, view: view) ?? false
            }

            view.onMouseDraggedInView = { [weak self] event, view in
                self?.handleMouseDragged(event: event, view: view)
            }

            view.onMouseUpInView = { [weak self] event, view in
                self?.handleMouseUp(event: event, view: view)
            }

            print("[RotoSceneVideoViewport] makeView created real SCNView viewport")

            return view
        }

        private func setupScene() {
            scene.background.contents = NSColor.black

            cameraNode.name = "RotoMotioniPhonePerspectiveCamera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.usesOrthographicProjection = false
            cameraNode.camera?.fieldOfView = CGFloat(currentCameraFOVDegrees)
            cameraNode.camera?.projectionDirection = .vertical
            cameraNode.camera?.zNear = 0.001
            cameraNode.camera?.zFar = 5000
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.look(at: SCNVector3(0, 0, -1))
            scene.rootNode.addChildNode(cameraNode)

            let initialPlaneHeight = perspectiveVideoPlaneHeight(
                cameraFOVDegrees: currentCameraFOVDegrees
            )
            videoPlaneSize = CGSize(
                width: initialPlaneHeight * 9.0 / 16.0,
                height: initialPlaneHeight
            )

            videoPlaneNode.name = "RotoMotionVideoUVCard"
            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: videoPlaneSize.width,
                height: videoPlaneSize.height,
                image: nil
            )
            videoPlaneNode.simdPosition = SIMD3<Float>(0, 0, currentVideoPlaneZ)
            scene.rootNode.addChildNode(videoPlaneNode)

            printCameraImagePlaneInvariant(reason: "setup")

            rawOverlayRoot.name = "RawVisionOverlayRoot"
            normalizedOverlayRoot.name = "NormalizedMeshyOverlayRoot"
            smoothedOverlayRoot.name = "SmoothedMeshyOverlayRoot"
            stereoDepthRoot.name = "StereoJointDepthRoot"
            groundRoot.name = "GroundPlaneRoot"
            visionRayRoot.name = "VisionRayRoot"
            solvedRigRoot.name = "RaySolvedRigRoot"
            solveErrorRoot.name = "RaySolveErrorRoot"
            rigBoundsRoot.name = "ReferenceRigBoundsRoot"

            scene.rootNode.addChildNode(groundRoot)
            scene.rootNode.addChildNode(rawOverlayRoot)
            scene.rootNode.addChildNode(normalizedOverlayRoot)
            scene.rootNode.addChildNode(smoothedOverlayRoot)
            scene.rootNode.addChildNode(stereoDepthRoot)
            scene.rootNode.addChildNode(visionRayRoot)
            scene.rootNode.addChildNode(solvedRigRoot)
            scene.rootNode.addChildNode(solveErrorRoot)
            scene.rootNode.addChildNode(rigBoundsRoot)
            scene.rootNode.addChildNode(rotationGizmo.root)

            groundRoot.addChildNode(makeGroundPlaneNode())
        }

        private func updateVideoPlaneZIfNeeded(_ z: Float) {
            guard abs(z - currentVideoPlaneZ) > 0.0001 || lastVideoPlaneZ.isNaN else {
                return
            }

            currentVideoPlaneZ = z
            videoPlaneNode.simdPosition = SIMD3<Float>(0, 0, z)
            lastVideoPlaneZ = z
            lastVideoPlaneSize = .zero
            lastVideoPlaneCameraFOVDegrees = -1
            printCameraImagePlaneInvariant(reason: "plane z changed")
        }

        private func printCameraImagePlaneInvariant(reason: String) {
            print(
                """
                [RotoSceneVideoViewport] Camera/ImagePlane invariant
                  reason: \(reason)
                  cameraZ: 0
                  imagePlaneZ: \(currentVideoPlaneZ)
                  expected imagePlaneZ < referenceRigZ < cameraZ
                """
            )
        }

        func update(
            view: SCNView,
            image: NSImage?,
            frameIndex: Int,
            rawFrame: RawVisionPoseCapture.PoseFrame?,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            smoothedFrame: SmoothedMeshyPoseCapture.Frame?,
            stereoJointFrame: StereoMeshyJointCapture.Frame?,
            groundPlane: GroundPlaneController?,
            raySolveResult: RotoRaySolveResult?,
            raySolvedFrame: RotoRayAnimationSolveResult.Frame?,
            skinnedRigSession: SkinnedRigSession?,
            cameraFOVDegrees: Double,
            cameraProfileName: String,
            currentVideoPlaneZ: Float,
            referenceRigScaleMultiplier: Double,
            referenceRigX: Double,
            referenceRigY: Double,
            referenceRigZ: Double,
            referenceRigYawDegrees: Double,
            applySolvedPoseToReferenceRig: Bool,
            rigRotationApplyMode: RigRotationApplyMode,
            rotationOverrideLayer: JointRotationOverrideLayer,
            heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
            liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
            liveRotationOverridesActive: Bool,
            rotationOverrideRevision: Int,
            showRawVision: Bool,
            showNormalizedMeshy: Bool,
            showSmoothedMeshy: Bool,
            showStereoJointDepth: Bool,
            showGroundPlane: Bool,
            showVisionRays: Bool,
            showRaySolvedRig: Bool,
            showSkinnedRig: Bool,
            showRotationGizmo: Bool,
            stereoSceneUnitsPerMeter: Double,
            rotationGizmoSpace: RotationGizmoSpace,
            selectedRotationJoint: String
        ) {
            self.selectedRotationJoint = selectedRotationJoint
            self.currentSkinnedRigSession = skinnedRigSession
            self.heldRotationOverrideEulerXYZByJoint = heldRotationOverrideEulerXYZByJoint
            self.liveRotationOverrideEulerXYZByJoint = liveRotationOverrideEulerXYZByJoint
            self.showRotationGizmo = showRotationGizmo

            view.allowsCameraControl = false
            view.pointOfView = cameraNode
            updateVideoPlaneZIfNeeded(currentVideoPlaneZ)
            updatePerspectiveCameraIfNeeded(
                cameraFOVDegrees: cameraFOVDegrees,
                cameraProfileName: cameraProfileName
            )

            if let image {
                updateVideoPlaneIfNeeded(
                    image: image,
                    frameIndex: frameIndex,
                    cameraFOVDegrees: cameraFOVDegrees
                )
            } else {
                clearVideoPlaneIfNeeded()
            }
            updateGroundPlane(groundPlane: groundPlane, visible: showGroundPlane)
            updateSkinnedRig(
                session: skinnedRigSession,
                frame: raySolvedFrame,
                frameIndex: frameIndex,
                normalizedFrame: normalizedFrame,
                referenceRigScaleMultiplier: referenceRigScaleMultiplier,
                referenceRigX: referenceRigX,
                referenceRigY: referenceRigY,
                referenceRigZ: referenceRigZ,
                referenceRigYawDegrees: referenceRigYawDegrees,
                applySolvedPoseToReferenceRig: applySolvedPoseToReferenceRig,
                rigRotationApplyMode: rigRotationApplyMode,
                rotationOverrideLayer: rotationOverrideLayer,
                heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
                liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
                liveRotationOverridesActive: liveRotationOverridesActive,
                visible: showSkinnedRig
            )
            rotationGizmo.root.isHidden = !showRotationGizmo
            logRotationGizmoVisibilityIfNeeded(showRotationGizmo: showRotationGizmo)

            if showRotationGizmo {
                updateRotationGizmo(
                    session: skinnedRigSession,
                    selectedJoint: selectedRotationJoint,
                    visible: true,
                    space: rotationGizmoSpace,
                    view: view
                )
            } else {
                rotationGizmo.root.isHidden = true
            }

            updateRawOverlay(rawFrame, visible: showRawVision)
            updateNormalizedOverlay(normalizedFrame, visible: showNormalizedMeshy)
            updateSmoothedOverlay(smoothedFrame, visible: showSmoothedMeshy)
            updateStereoDepthOverlay(
                stereoJointFrame,
                visible: showStereoJointDepth,
                sceneUnitsPerMeter: stereoSceneUnitsPerMeter
            )
            updateRaySolveDebug(
                result: raySolveResult,
                raySolvedFrame: raySolvedFrame,
                showRays: showVisionRays,
                showSolvedRig: showRaySolvedRig
            )
        }

        private func updateVideoPlaneIfNeeded(
            image: NSImage,
            frameIndex: Int,
            cameraFOVDegrees: Double
        ) {
            let imageObjectID = ObjectIdentifier(image)

            let width = max(image.size.width, 1)
            let height = max(image.size.height, 1)
            let imageSize = CGSize(width: width, height: height)

            let imageChanged = frameIndex != lastImageToken || imageObjectID != lastImageObjectID
            let imageSizeChanged =
                abs(imageSize.width - lastVideoImageSize.width) > 0.5 ||
                abs(imageSize.height - lastVideoImageSize.height) > 0.5
            let cameraChanged = abs(cameraFOVDegrees - lastVideoPlaneCameraFOVDegrees) > 0.0001

            guard imageChanged || imageSizeChanged || cameraChanged else {
                return
            }

            lastImageToken = frameIndex
            lastImageObjectID = imageObjectID
            updateVideoPlaneMaterial(image: image)

            guard imageSizeChanged || cameraChanged else {
                return
            }

            lastVideoImageSize = imageSize
            let aspect = width / height

            let planeHeight = perspectiveVideoPlaneHeight(
                cameraFOVDegrees: cameraFOVDegrees
            )
            let planeWidth = planeHeight * aspect

            videoPlaneSize = CGSize(width: planeWidth, height: planeHeight)
            lastVideoPlaneCameraFOVDegrees = cameraFOVDegrees
            onVideoPlaneSizeChanged?(videoPlaneSize)

            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: planeWidth,
                height: planeHeight,
                image: image
            )

            lastVideoPlaneSize = .zero

            print(
                """
                [RotoSceneVideoViewport] Updated UV video card geometry
                  frame: \(frameIndex)
                  imageSize: \(image.size)
                  cameraProfile: \(currentCameraProfileName)
                  verticalFOV: \(String(format: "%.3f", cameraFOVDegrees))
                  imagePlaneZ: \(currentVideoPlaneZ)
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
            lastVideoImageSize = .zero
            let planeHeight = perspectiveVideoPlaneHeight(
                cameraFOVDegrees: currentCameraFOVDegrees
            )
            videoPlaneSize = CGSize(width: planeHeight * 9.0 / 16.0, height: planeHeight)
            lastVideoPlaneCameraFOVDegrees = currentCameraFOVDegrees
            onVideoPlaneSizeChanged?(videoPlaneSize)
            videoPlaneNode.geometry = makeVideoPlaneGeometry(
                width: videoPlaneSize.width,
                height: videoPlaneSize.height,
                image: nil
            )
            lastVideoPlaneSize = .zero
        }

        private func updateVideoPlaneMaterial(image: NSImage) {
            guard let material = videoPlaneNode.geometry?.materials.first else {
                return
            }

            material.diffuse.contents = image
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

        private func updatePerspectiveCameraIfNeeded(
            cameraFOVDegrees: Double,
            cameraProfileName: String
        ) {
            guard let camera = cameraNode.camera else {
                return
            }

            let changed =
                abs(cameraFOVDegrees - lastAppliedCameraFOVDegrees) > 0.0001 ||
                cameraProfileName != currentCameraProfileName ||
                camera.usesOrthographicProjection

            currentCameraFOVDegrees = cameraFOVDegrees
            currentCameraProfileName = cameraProfileName

            camera.usesOrthographicProjection = false
            camera.fieldOfView = CGFloat(cameraFOVDegrees)
            camera.projectionDirection = .vertical
            camera.zNear = 0.001
            camera.zFar = 5000

            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.look(at: SCNVector3(0, 0, -1))

            guard changed else {
                return
            }

            lastAppliedCameraFOVDegrees = cameraFOVDegrees
            lastVideoPlaneSize = .zero

            print(
                """
                [RotoSceneVideoViewport] Perspective Camera Applied
                  cameraProfile: \(cameraProfileName)
                  usesOrthographicProjection: false
                  fieldOfView: \(String(format: "%.3f", cameraFOVDegrees))
                  projectionDirection: vertical
                  imagePlaneZ: \(currentVideoPlaneZ)
                """
            )
        }

        private func perspectiveVideoPlaneHeight(cameraFOVDegrees: Double) -> CGFloat {
            let distance = CGFloat(abs(currentVideoPlaneZ))
            let fovRadians = CGFloat(cameraFOVDegrees) * .pi / 180.0
            return 2.0 * distance * tan(fovRadians * 0.5)
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
                currentVideoPlaneZ + zOffset
            )
        }

        private func pointOnCurrentImagePlane(
            x: Double,
            y: Double,
            zOffsetTowardCamera: Float
        ) -> SIMD3<Float> {
            let px = (Float(x) - 0.5) * Float(videoPlaneSize.width)
            let py = (Float(y) - 0.5) * Float(videoPlaneSize.height)

            return SIMD3<Float>(
                px,
                py,
                currentVideoPlaneZ + zOffsetTowardCamera
            )
        }

        private func currentRawVisionPointRadius() -> CGFloat {
            max(0.75, videoPlaneSize.height * 0.0015)
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

            var count = 0

            for (_, joint) in frame.joints {
                let p = pointOnCurrentImagePlane(
                    x: joint.x,
                    y: joint.y,
                    zOffsetTowardCamera: 0.50
                )

                let node = makePointNode(
                    color: NSColor.systemOrange.withAlphaComponent(
                        CGFloat(max(0.25, min(joint.confidence, 1.0)))
                    ),
                    radius: currentRawVisionPointRadius()
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 500
                rawOverlayRoot.addChildNode(node)

                count += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print(
                    """
                    [RotoSceneVideoViewport] Raw Vision overlay updated
                      visible: \(visible)
                      frame: \(frame.frameIndex)
                      jointsDrawn: \(count)
                    """
                )
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

        private func updateStereoDepthOverlay(
            _ frame: StereoMeshyJointCapture.Frame?,
            visible: Bool,
            sceneUnitsPerMeter: Double
        ) {
            stereoDepthRoot.isHidden = !visible
            removeAllChildren(from: stereoDepthRoot)

            guard visible, let frame else {
                return
            }

            let scale = Float(max(sceneUnitsPerMeter, 0.0001))
            var positions: [String: SIMD3<Float>] = [:]

            for (name, joint) in frame.joints where joint.validStereo && joint.positionCameraXYZ.count == 3 {
                positions[name] = SIMD3<Float>(
                    Float(joint.positionCameraXYZ[0]) * scale,
                    Float(joint.positionCameraXYZ[1]) * scale,
                    Float(joint.positionCameraXYZ[2]) * scale
                )
            }

            let color = NSColor.magenta

            for (a, b) in meshySkeletonBones {
                guard let pa = positions[a],
                      let pb = positions[b] else {
                    continue
                }

                stereoDepthRoot.addChildNode(
                    makeLineNode(
                        from: SCNVector3(pa.x, pa.y, pa.z),
                        to: SCNVector3(pb.x, pb.y, pb.z),
                        color: color.withAlphaComponent(0.85)
                    )
                )
            }

            for (_, p) in positions {
                let node = makePointNode(
                    color: color,
                    radius: 0.055
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 700
                stereoDepthRoot.addChildNode(node)
            }
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
            for (a, b) in meshySkeletonBones {
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

        private var meshySkeletonBones: [(String, String)] {
            [
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

        private func updateSkinnedRig(
            session: SkinnedRigSession?,
            frame: RotoRayAnimationSolveResult.Frame?,
            frameIndex: Int,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            referenceRigScaleMultiplier: Double,
            referenceRigX: Double,
            referenceRigY: Double,
            referenceRigZ: Double,
            referenceRigYawDegrees: Double,
            applySolvedPoseToReferenceRig: Bool,
            rigRotationApplyMode: RigRotationApplyMode,
            rotationOverrideLayer: JointRotationOverrideLayer,
            heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
            liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>],
            liveRotationOverridesActive: Bool,
            visible: Bool
        ) {
            guard let session else {
                skinnedRigRoot?.removeFromParentNode()
                skinnedRigRoot = nil
                currentSkinnedRigURL = nil
                lastRigFitSignature = nil
                lastReferenceRigPlacementSignature = nil
                lastReferenceRigOverlaySignature = nil
                removeAllChildren(from: rigBoundsRoot)
                return
            }

            if currentSkinnedRigURL != session.sourceURL || skinnedRigRoot !== session.displayRootNode {
                skinnedRigRoot?.removeFromParentNode()

                if session.displayRootNode.parent !== scene.rootNode {
                    session.displayRootNode.removeFromParentNode()
                    scene.rootNode.addChildNode(session.displayRootNode)
                }

                skinnedRigRoot = session.displayRootNode
                currentSkinnedRigURL = session.sourceURL
                lastRigFitSignature = nil
                lastReferenceRigPlacementSignature = nil
                lastReferenceRigOverlaySignature = nil
                removeAllChildren(from: rigBoundsRoot)

                print(
                    """
                    [RotoMotion Session] Loaded real skinned rig into viewport
                      url: \(session.sourceURL.path)
                      matchedBones: \(session.validBoneCount)
                    """
                )
            }

            session.displayRootNode.isHidden = !visible
            rigBoundsRoot.isHidden = !visible

            if applySolvedPoseToReferenceRig,
               let frame,
               let normalizedFrame {
                SkinnedRigRotomationDriver.rotomateFrameWithCurvePins(
                    frame,
                    normalizedFrame: normalizedFrame,
                    session: session,
                    cameraOrigin: SIMD3<Float>(0, 0, 0),
                    videoPlaneSize: videoPlaneSize,
                    videoPlaneZ: currentVideoPlaneZ
                )

                applyViewportRotationOverrides(
                    session: session,
                    overrideLayer: rotationOverrideLayer,
                    liveOverridesActive: liveRotationOverridesActive,
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds
                )

                if frameIndex % 30 == 0,
                   lastCurvePinnedPlaybackLogFrame != frameIndex {
                    print("[RotoMotion Playback] Applied curve-pinned rig frame \(frameIndex)")
                    lastCurvePinnedPlaybackLogFrame = frameIndex
                }
            } else {
                SkinnedRigRotomationDriver.resetToRest(session: session)
            }
        }

        private func updateRotationGizmo(
            session: SkinnedRigSession?,
            selectedJoint: String,
            visible: Bool,
            space: RotationGizmoSpace,
            view: SCNView
        ) {
            guard visible,
                  let session,
                  let bone = session.bonesByCanonicalName[selectedJoint] else {
                rotationGizmo.setVisible(false)
                return
            }

            rotationGizmo.update(
                selectedBone: bone,
                cameraNode: cameraNode,
                view: view,
                space: space,
                visible: visible
            )
        }

        private func applyViewportRotationOverrides(
            session: SkinnedRigSession,
            overrideLayer: JointRotationOverrideLayer,
            liveOverridesActive: Bool,
            frameIndex: Int,
            timeSeconds: Double
        ) {
            for joint in CanonicalRig.jointNames {
                guard let bone = session.bonesByCanonicalName[joint] else {
                    continue
                }

                guard let overrideValue = JointRotationOverrideApplier.rotationOverrideEuler(
                    joint: joint,
                    frameIndex: frameIndex,
                    timeSeconds: timeSeconds,
                    overrideLayer: overrideLayer,
                    heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
                    liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
                    liveOverridesActive: liveOverridesActive
                ) else {
                    continue
                }

                let clamped = ManualRotationConstraint.clampedEulerXYZ(
                    joint: joint,
                    values: overrideValue
                )

                bone.simdEulerAngles = clamped
                logRotationOverrideIfNeeded(joint: joint, euler: clamped)
            }
        }

        func handleMouseDown(
            event: NSEvent,
            view: RotoSCNView
        ) -> Bool {
            guard showRotationGizmo,
                  !rotationGizmo.root.isHidden else {
                return false
            }

            let point = view.convert(event.locationInWindow, from: nil)
            let hits = view.hitTest(
                point,
                options: [
                    SCNHitTestOption.boundingBoxOnly: false,
                    SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
                ]
            )

            guard let ringHit = hits.compactMap({ hit -> (SCNHitTestResult, ViewportJointRotationGizmo.Axis)? in
                guard let axis = rotationGizmo.axisFromHitNode(hit.node) else {
                    return nil
                }

                return (hit, axis)
            }).first else {
                return false
            }

            let hitAxis = ringHit.1
            let pivot = rotationGizmo.root.simdWorldPosition
            let axisWorld = rotationGizmo.worldAxis(for: hitAxis)
            let hitPoint = simdVector(ringHit.0.worldCoordinates)

            let startVector = normalizeSafe(
                hitPoint - pivot,
                fallback: SIMD3<Float>(1, 0, 0)
            )

            activeGizmoAxis = hitAxis
            activeGizmoJoint = selectedRotationJoint
            activeGizmoPivotWorld = pivot
            activeGizmoAxisWorld = axisWorld
            activeGizmoStartVectorWorld = startVector
            activeGizmoStartEuler = currentEulerForSelectedJoint()
            onRotationGizmoStatus?("Started \(hitAxis.rawValue) rotation for \(selectedRotationJoint)")

            return true
        }

        func handleMouseDragged(
            event: NSEvent,
            view: RotoSCNView
        ) {
            guard let axis = activeGizmoAxis,
                  let joint = activeGizmoJoint,
                  let pivot = activeGizmoPivotWorld,
                  let axisWorld = activeGizmoAxisWorld,
                  let startVector = activeGizmoStartVectorWorld,
                  var euler = activeGizmoStartEuler else {
                return
            }

            let point = view.convert(event.locationInWindow, from: nil)

            guard let hitPoint = rayPlaneIntersectionFromMouse(
                point: point,
                view: view,
                planePoint: pivot,
                planeNormal: axisWorld
            ) else {
                return
            }

            let currentVector = normalizeSafe(
                hitPoint - pivot,
                fallback: startVector
            )

            let dot = max(Float(-1.0), min(Float(1.0), simd_dot(startVector, currentVector)))
            let unsigned = acos(dot)
            let sign: Float = simd_dot(axisWorld, simd_cross(startVector, currentVector)) >= 0 ? 1 : -1
            let angle = unsigned * sign

            switch axis {
            case .x:
                euler.x += angle
            case .y:
                euler.y += angle
            case .z:
                euler.z += angle
            }

            euler = ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: euler
            )

            onRotationGizmoEulerChanged?(joint, euler)
        }

        func handleMouseUp(
            event: NSEvent,
            view: RotoSCNView
        ) {
            let endedJoint = activeGizmoJoint
            activeGizmoAxis = nil
            activeGizmoJoint = nil
            activeGizmoPivotWorld = nil
            activeGizmoAxisWorld = nil
            activeGizmoStartVectorWorld = nil
            activeGizmoStartEuler = nil

            if let endedJoint {
                onRotationGizmoStatus?("Ended rotation for \(endedJoint)")
                onRotationGizmoDragEnded?()
            }
        }

        private func currentEulerForSelectedJoint() -> SIMD3<Float> {
            liveRotationOverrideEulerXYZByJoint[selectedRotationJoint]
                ?? heldRotationOverrideEulerXYZByJoint[selectedRotationJoint]
                ?? currentSkinnedRigSession?.bonesByCanonicalName[selectedRotationJoint]?.simdEulerAngles
                ?? SIMD3<Float>(0, 0, 0)
        }

        private func rayPlaneIntersectionFromMouse(
            point: CGPoint,
            view: SCNView,
            planePoint: SIMD3<Float>,
            planeNormal: SIMD3<Float>
        ) -> SIMD3<Float>? {
            let near = view.unprojectPoint(
                SCNVector3(Float(point.x), Float(point.y), 0)
            )
            let far = view.unprojectPoint(
                SCNVector3(Float(point.x), Float(point.y), 1)
            )

            let origin = SIMD3<Float>(
                Float(near.x),
                Float(near.y),
                Float(near.z)
            )
            let farPoint = SIMD3<Float>(
                Float(far.x),
                Float(far.y),
                Float(far.z)
            )
            let direction = normalizeSafe(
                farPoint - origin,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            let normal = normalizeSafe(
                planeNormal,
                fallback: SIMD3<Float>(0, 0, 1)
            )
            let denom = simd_dot(direction, normal)

            guard abs(denom) > 0.000001 else {
                return nil
            }

            let t = simd_dot(planePoint - origin, normal) / denom

            guard t.isFinite else {
                return nil
            }

            return origin + direction * t
        }

        private func simdVector(_ value: SCNVector3) -> SIMD3<Float> {
            SIMD3<Float>(
                Float(value.x),
                Float(value.y),
                Float(value.z)
            )
        }

        private func logRotationOverrideIfNeeded(
            joint: String,
            euler: SIMD3<Float>
        ) {
            guard joint == selectedRotationJoint else {
                return
            }

            let signature = "\(joint):\(String(format: "%.4f", euler.x)):\(String(format: "%.4f", euler.y)):\(String(format: "%.4f", euler.z))"
            guard signature != lastRotationOverrideLogSignature else {
                return
            }

            lastRotationOverrideLogSignature = signature
            print(
                """
                [RotoSceneVideoViewport] applied rotation override
                  joint: \(joint)
                  euler: \(euler)
                """
            )
        }

        private func logRotationGizmoVisibilityIfNeeded(showRotationGizmo: Bool) {
            let signature = "\(showRotationGizmo):\(rotationGizmo.root.isHidden)"
            guard signature != lastRotationGizmoVisibilitySignature else {
                return
            }

            lastRotationGizmoVisibilitySignature = signature
            print(
                """
                [RotoSceneVideoViewport] rotation gizmo visibility
                  showRotationGizmo: \(showRotationGizmo)
                  rootHidden: \(rotationGizmo.root.isHidden)
                """
            )
        }

        private func applyReferenceRigDisplayPlacement(
            session: SkinnedRigSession,
            x: Double,
            y: Double,
            z: Double
        ) {
            session.displayRootNode.simdPosition = SIMD3<Float>(
                Float(x),
                Float(y),
                Float(z)
            )

            session.displayRootNode.simdScale = SIMD3<Float>(1, 1, 1)

            session.displayRootNode.simdEulerAngles = SIMD3<Float>(
                -Float.pi / 2.0,
                Float.pi * 2.0,
                0
            )

            session.correctionNode.simdEulerAngles = SIMD3<Float>(0, 0, 0)
            session.displayRootNode.isHidden = false
            session.displayRootNode.opacity = 1.0

            forceReferenceRigVisible(session.displayRootNode)
            ReferenceRigMaterialOverlay.applyHalfOpacity(
                to: session.displayRootNode,
                opacity: 0.5
            )

            let signature = [
                session.sourceURL.path,
                String(format: "x=%.4f", x),
                String(format: "y=%.4f", y),
                String(format: "z=%.4f", z),
                "fixed-reference-display-transform"
            ].joined(separator: "|")

            if lastReferenceRigPlacementSignature != signature {
                lastReferenceRigPlacementSignature = signature
                let status = """
                Reference rig viewport transform:
                  position: \(session.displayRootNode.simdPosition)
                  scale: \(session.displayRootNode.simdScale)
                  rotationXDegrees: -90.0
                  rotationYDegrees: 360.0
                """
                print(status)
                onReferenceRigVisibilityStatusChanged?(status)
            }

            let overlaySignature = [
                session.sourceURL.path,
                "reference-material-overlay-0.5"
            ].joined(separator: "|")

            if lastReferenceRigOverlaySignature != overlaySignature {
                lastReferenceRigOverlaySignature = overlaySignature
                let status = """
                Applied reference rig material overlay:
                opacity 0.5
                blendMode alpha
                writesToDepthBuffer false
                readsFromDepthBuffer true
                doubleSided true
                """
                print(status)
                onReferenceRigVisibilityStatusChanged?(status)
            }
        }

        private func fitReferenceRigToCamera(
            session: SkinnedRigSession,
            referenceFitFrame: NormalizedMeshyPoseCapture.Frame?,
            view: SCNView,
            targetZ: Float,
            yawCorrection: Float,
            scaleVisualReduction: Float
        ) {
            guard let camera = cameraNode.camera else {
                let message = "[RotoSceneVideoViewport] ERROR: no camera for rig fit"
                print(message)
                onReferenceRigVisibilityStatusChanged?("Reference rig fit failed: no camera.")
                return
            }

            guard let referenceFitFrame else {
                let message = "[RotoSceneVideoViewport] ERROR: no normalized frame 0 for Hips<->Spine reference fit"
                print(message)
                onReferenceRigVisibilityStatusChanged?("Reference rig fit failed: missing normalized frame 0.")
                return
            }

            guard let normalizedHips = referenceFitFrame.joints["Hips"],
                  let normalizedSpine = referenceFitFrame.joints["Spine"],
                  !normalizedHips.missing,
                  !normalizedSpine.missing else {
                let message = "[RotoSceneVideoViewport] ERROR: normalized frame 0 missing Hips/Spine for reference fit"
                print(message)
                onReferenceRigVisibilityStatusChanged?("Reference rig fit failed: normalized frame 0 missing Hips/Spine.")
                return
            }

            guard let hipsNode = session.bonesByCanonicalName["Hips"],
                  let spineNode = session.bonesByCanonicalName["Spine"] else {
                let message = "[RotoSceneVideoViewport] ERROR: skinned rig missing Hips/Spine bones for reference fit"
                print(message)
                onReferenceRigVisibilityStatusChanged?("Reference rig fit failed: skinned rig missing Hips/Spine bones.")
                return
            }

            let safeScaleReduction = max(scaleVisualReduction, 0.0001)

            session.displayRootNode.simdPosition = SIMD3<Float>(0, 0, targetZ)
            session.displayRootNode.simdScale = SIMD3<Float>(repeating: 1.0)
            session.displayRootNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
            session.correctionNode.simdEulerAngles = SIMD3<Float>(0, yawCorrection, 0)
            session.displayRootNode.isHidden = false
            session.displayRootNode.opacity = 1.0
            SkinnedRigRotomationDriver.resetToRest(session: session)
            normalizeReferenceRigScreenOrientation(
                session: session,
                targetZ: targetZ
            )
            forceReferenceRigVisible(session.displayRootNode)

            view.layoutSubtreeIfNeeded()

            let targetHipsWorld = worldPointOnRigDepth(
                normalizedX: normalizedHips.x,
                normalizedY: normalizedHips.y,
                rigZ: targetZ
            )

            let targetSpineWorld = worldPointOnRigDepth(
                normalizedX: normalizedSpine.x,
                normalizedY: normalizedSpine.y,
                rigZ: targetZ
            )

            let normalizedTarget2D = distance2D(
                CGPoint(x: normalizedHips.x, y: normalizedHips.y),
                CGPoint(x: normalizedSpine.x, y: normalizedSpine.y)
            )

            let targetHipsScreen = projectedScreenPoint(
                world: targetHipsWorld,
                view: view
            )

            let targetSpineScreen = projectedScreenPoint(
                world: targetSpineWorld,
                view: view
            )

            let targetScreenLength = distance2D(targetHipsScreen, targetSpineScreen)

            let currentHipsWorld = worldPosition(of: hipsNode)
            let currentSpineWorld = worldPosition(of: spineNode)
            let currentHipsScreen = projectedScreenPoint(
                world: currentHipsWorld,
                view: view
            )

            let currentSpineScreen = projectedScreenPoint(
                world: currentSpineWorld,
                view: view
            )

            let currentRigProjected2D = distance2D(currentHipsScreen, currentSpineScreen)
            let fitScale = Float(targetScreenLength / max(currentRigProjected2D, 0.0001))
            let appliedScale = fitScale * safeScaleReduction

            session.displayRootNode.simdScale = SIMD3<Float>(repeating: appliedScale)
            view.layoutSubtreeIfNeeded()

            let scaledHipsWorld = worldPosition(of: hipsNode)
            let hipsDelta = targetHipsWorld - scaledHipsWorld
            session.displayRootNode.simdPosition.x += hipsDelta.x
            session.displayRootNode.simdPosition.y += hipsDelta.y
            session.displayRootNode.simdPosition.z = targetZ

            forceReferenceRigVisible(session.displayRootNode)

            let finalBox = worldBoundingBox(node: session.displayRootNode)
            updateRigBoundsBox(box: finalBox)

            let finalCenter = finalBox.map { ($0.min + $0.max) * 0.5 } ?? .zero
            let finalSize = finalBox.map { $0.max - $0.min } ?? .zero
            let invariant = currentVideoPlaneZ < targetZ && targetZ < 0

            let status = """
            Reference display fit from Hips<->Spine:
            target2D \(String(format: "%.3f", normalizedTarget2D))
            rig2D \(String(format: "%.3f", currentRigProjected2D))
            fitScale \(String(format: "%.5f", fitScale))
            appliedScale \(String(format: "%.5f", appliedScale))
            bbox \(String(format: "%.3f", finalSize.x)) x \(String(format: "%.3f", finalSize.y))
            center \(String(format: "%.3f", finalCenter.x)), \(String(format: "%.3f", finalCenter.y)), \(String(format: "%.3f", finalCenter.z))
            scale \(String(format: "%.5f", appliedScale))
            z \(String(format: "%.3f", session.displayRootNode.simdPosition.z))
            """

            onReferenceRigVisibilityStatusChanged?(status)

            print(
                """
                [RotoSceneVideoViewport] Reference rig fitted to camera
                  cameraPerspective: \(!camera.usesOrthographicProjection)
                  viewBounds: \(view.bounds)
                  targetZ: \(targetZ)
                  yawCorrection: \(yawCorrection)
                  scaleVisualReduction: \(safeScaleReduction)
                  normalizedTarget2D: \(normalizedTarget2D)
                  targetScreen2D: \(targetScreenLength)
                  currentRigProjected2D: \(currentRigProjected2D)
                  fitScale: \(fitScale)
                  appliedScale: \(appliedScale)
                  targetHipsWorld: \(targetHipsWorld)
                  finalPosition: \(session.displayRootNode.simdPosition)
                  finalBBoxCenter: \(finalCenter)
                  finalBBoxSize: \(finalSize)
                  invariantBetweenCameraAndPlane: \(invariant)
                """
            )
        }

        private func normalizeReferenceRigScreenOrientation(
            session: SkinnedRigSession,
            targetZ: Float
        ) {
            session.displayRootNode.simdPosition = SIMD3<Float>(0, 0, targetZ)
            session.displayRootNode.simdScale = SIMD3<Float>(repeating: 1.0)

            guard let hips = session.bonesByCanonicalName["Hips"],
                  let spine = session.bonesByCanonicalName["Spine"] else {
                print("[RotoSceneVideoViewport] Reference rig screen orientation skipped: missing Hips/Spine bones")
                return
            }

            let hipsWorld = worldPosition(of: hips)
            let spineWorld = worldPosition(of: spine)
            let torso = spineWorld - hipsWorld
            let torsoXY = SIMD2<Float>(torso.x, torso.y)
            let len2 = simd_dot(torsoXY, torsoXY)

            guard len2 > 0.000001 else {
                print("[RotoSceneVideoViewport] Reference rig screen orientation skipped: Hips->Spine has no screen length")
                return
            }

            let currentAngle = atan2(torsoXY.y, torsoXY.x)
            let targetAngle = Float.pi * 0.5
            let correction = targetAngle - currentAngle

            session.displayRootNode.simdOrientation = simd_quatf(
                angle: correction,
                axis: SIMD3<Float>(0, 0, 1)
            )

            let correctedHips = worldPosition(of: hips)
            let correctedSpine = worldPosition(of: spine)
            let correctedTorso = correctedSpine - correctedHips

            print(
                """
                [RotoSceneVideoViewport] Reference rig screen orientation normalized
                  hipsWorld: \(hipsWorld)
                  spineWorld: \(spineWorld)
                  torsoXY: \(torsoXY)
                  correctionDegrees: \(correction * 180.0 / Float.pi)
                  correctedTorso: \(correctedTorso)
                """
            )
        }

        private func worldPosition(of node: SCNNode) -> SIMD3<Float> {
            let position = node.convertPosition(SCNVector3(0, 0, 0), to: nil)

            return SIMD3<Float>(
                Float(position.x),
                Float(position.y),
                Float(position.z)
            )
        }

        private func worldPointOnRigDepth(
            normalizedX: Double,
            normalizedY: Double,
            rigZ: Float
        ) -> SIMD3<Float> {
            let pointOnPlane = SIMD3<Float>(
                Float((CGFloat(normalizedX) - 0.5) * videoPlaneSize.width),
                Float((CGFloat(normalizedY) - 0.5) * videoPlaneSize.height),
                currentVideoPlaneZ
            )

            let cameraOrigin = SIMD3<Float>(0, 0, 0)
            let direction = normalizeSafe(
                pointOnPlane - cameraOrigin,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            guard abs(direction.z) > 0.000001 else {
                return SIMD3<Float>(pointOnPlane.x, pointOnPlane.y, rigZ)
            }

            let t = (rigZ - cameraOrigin.z) / direction.z
            return cameraOrigin + direction * max(t, 0)
        }

        private func projectedScreenPoint(
            world: SIMD3<Float>,
            view: SCNView
        ) -> CGPoint {
            let projected = view.projectPoint(
                SCNVector3(world.x, world.y, world.z)
            )

            return CGPoint(
                x: CGFloat(projected.x),
                y: CGFloat(projected.y)
            )
        }

        private func distance2D(
            _ a: CGPoint,
            _ b: CGPoint
        ) -> Double {
            let dx = Double(a.x - b.x)
            let dy = Double(a.y - b.y)
            return sqrt(dx * dx + dy * dy)
        }

        private func normalizeSafe(
            _ value: SIMD3<Float>,
            fallback: SIMD3<Float>
        ) -> SIMD3<Float> {
            guard simd_length_squared(value) > 0.0000001 else {
                return fallback
            }

            return simd_normalize(value)
        }

        private func forceReferenceRigVisible(_ root: SCNNode) {
            visit(root) { node in
                node.isHidden = false
                node.opacity = 1.0
            }
        }

        private func worldBoundingBox(
            node: SCNNode
        ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
            var found = false

            var outMin = SIMD3<Float>(
                Float.greatestFiniteMagnitude,
                Float.greatestFiniteMagnitude,
                Float.greatestFiniteMagnitude
            )

            var outMax = SIMD3<Float>(
                -Float.greatestFiniteMagnitude,
                -Float.greatestFiniteMagnitude,
                -Float.greatestFiniteMagnitude
            )

            visit(node) { child in
                guard child.geometry != nil else {
                    return
                }

                let box = child.boundingBox

                let corners = [
                    SCNVector3(box.min.x, box.min.y, box.min.z),
                    SCNVector3(box.max.x, box.min.y, box.min.z),
                    SCNVector3(box.min.x, box.max.y, box.min.z),
                    SCNVector3(box.max.x, box.max.y, box.min.z),
                    SCNVector3(box.min.x, box.min.y, box.max.z),
                    SCNVector3(box.max.x, box.min.y, box.max.z),
                    SCNVector3(box.min.x, box.max.y, box.max.z),
                    SCNVector3(box.max.x, box.max.y, box.max.z)
                ]

                for corner in corners {
                    let w = child.convertPosition(corner, to: nil)
                    let p = SIMD3<Float>(
                        Float(w.x),
                        Float(w.y),
                        Float(w.z)
                    )

                    outMin = SIMD3<Float>(
                        Swift.min(outMin.x, p.x),
                        Swift.min(outMin.y, p.y),
                        Swift.min(outMin.z, p.z)
                    )

                    outMax = SIMD3<Float>(
                        Swift.max(outMax.x, p.x),
                        Swift.max(outMax.y, p.y),
                        Swift.max(outMax.z, p.z)
                    )

                    found = true
                }
            }

            return found ? (outMin, outMax) : nil
        }

        private func updateRigBoundsBox(box: (min: SIMD3<Float>, max: SIMD3<Float>)?) {
            removeAllChildren(from: rigBoundsRoot)

            guard let box else {
                return
            }

            let min = box.min
            let max = box.max

            let corners = [
                SIMD3<Float>(min.x, min.y, min.z),
                SIMD3<Float>(max.x, min.y, min.z),
                SIMD3<Float>(min.x, max.y, min.z),
                SIMD3<Float>(max.x, max.y, min.z),
                SIMD3<Float>(min.x, min.y, max.z),
                SIMD3<Float>(max.x, min.y, max.z),
                SIMD3<Float>(min.x, max.y, max.z),
                SIMD3<Float>(max.x, max.y, max.z)
            ]

            let edges = [
                (0, 1), (0, 2), (1, 3), (2, 3),
                (4, 5), (4, 6), (5, 7), (6, 7),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                let node = makeLineNode(
                    from: SCNVector3(corners[edge.0]),
                    to: SCNVector3(corners[edge.1]),
                    color: NSColor.systemPink.withAlphaComponent(0.95)
                )
                node.renderingOrder = 200
                rigBoundsRoot.addChildNode(node)
            }

            rigBoundsRoot.isHidden = false
        }

        private func visit(_ node: SCNNode, _ body: (SCNNode) -> Void) {
            body(node)

            for child in node.childNodes {
                visit(child, body)
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
            if !didLogDrawnSolvedRigPoseSource {
                didLogDrawnSolvedRigPoseSource = true
                print("[RotoMotion Session] Solved rig viewport is drawn from jointPositions, not posed armature local transforms.")
            }

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
