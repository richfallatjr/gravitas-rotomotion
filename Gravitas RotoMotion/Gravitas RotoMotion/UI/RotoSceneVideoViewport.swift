import AppKit
import Foundation
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
    let vision3DFrame: NormalizedVision3DMeshyCapture.Frame?
    let rightRawFrame: RawVisionPoseCapture.PoseFrame?
    let rightNormalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let stereoJointFrame: StereoMeshyJointCapture.Frame?
    let conditionedStereoFrame: ConditionedStereoJointCapture.Frame?
    let jointDepthEvidenceFrame: JointDepthEvidenceCapture.Frame?
    let disparityPreviewFrame: SpatialDisparityPreviewCapture.Frame?
    let fusedStereoTargetFrame: FusedStereoJointTargetCapture.Frame?

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
    let liveRotationPreviewFrameIndexByJoint: [String: Int]
    let liveRotationOverridesActive: Bool
    let liveRigPoseSource: LiveRigPoseSource
    let skin3DApplyRevision: Int
    let skin3DViewportRefreshRevision: Int
    let vision3DSkinningAlignmentState: Vision3DSkinningAlignmentState
    let viewportRefreshRevision: Int
    let rotationOverrideRevision: Int
    let rotationKeyRevision: Int
    let selectedJointRotationFieldRevision: Int
    let spatialDepthControlRevision: Int
    let spatialCameraOffsetRevision: Int
    let spatialSolveTriggerRevision: Int
    let visibilityToggleRevision: Int
    let solveInputRevision: Int
    let disparityProgressRevision: Int
    let lastViewportRefreshReason: String

    let showRawVision: Bool
    let showNormalizedMeshy: Bool
    let showVision3DSkeleton: Bool
    let showVision3DProjectionOverlay: Bool
    let showRightEyeVisionOverlay: Bool
    let showRightEyeNormalizedOverlay: Bool
    let showSmoothedMeshy: Bool
    let showStereo3DSkeleton: Bool
    let showConditionedStereoSkeleton: Bool
    let showStereoReprojectionOverlay: Bool
    let showJointDepthValidationOverlay: Bool
    let showDisparityOnImagePlane: Bool
    let selectedDisparityPlateOverlay: DisparityPlateOverlayKind
    let disparityPlateOverlayOpacity: Double
    let showFusedStereoTargets: Bool
    let showSpatialTargetBalls: Bool
    let spatialTargetBallScale: Double
    let showGroundPlane: Bool
    let showVisionRays: Bool
    let showRaySolvedRig: Bool
    let showSkinnedRig: Bool
    let showSkinnedGeometry: Bool
    let showRotationGizmo: Bool
    let stereoMetersToRigSceneUnits: Float
    let stereoToRigAlignment: StereoToRigAlignment
    let solveTargetMode: RotoSolveTargetMode
    let spatialRayPinDepthMode: SpatialRayPinDepthMode
    let spatialRayPinDepthFitSettings: SpatialRayPinDepthFitSettings
    let autoSpatialDepthFitEnabled: Bool
    let manualSpatialCameraPanX: Double
    let manualSpatialCameraPanY: Double
    let manualSpatialCameraDepthZ: Double
    let rotationGizmoSpace: RotationGizmoSpace
    let selectedRotationJoint: String
    let onRotationGizmoEulerChanged: (_ joint: String, _ eulerXYZ: SIMD3<Float>) -> Void
    let onRotationGizmoStatus: (_ status: String) -> Void
    let onRotationGizmoDragEnded: (() -> Void)?
    let onVideoPlaneSizeChanged: ((CGSize) -> Void)?
    let onReferenceRigVisibilityStatusChanged: ((String) -> Void)?
    let onSpatialSolveTrace: (SpatialSolveTrace) -> Void
    let onSpatialDepthFitReadback: (
        _ autoZoom: Double,
        _ autoOffset: Double,
        _ score: Double,
        _ residual: Double
    ) -> Void

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
        context.coordinator.onSpatialSolveTrace = onSpatialSolveTrace
        context.coordinator.onSpatialDepthFitReadback = onSpatialDepthFitReadback
        context.coordinator.update(
            view: view,
            image: image,
            frameIndex: frameIndex,
            rawFrame: rawFrame,
            normalizedFrame: normalizedFrame,
            vision3DFrame: vision3DFrame,
            rightRawFrame: rightRawFrame,
            rightNormalizedFrame: rightNormalizedFrame,
            smoothedFrame: smoothedFrame,
            stereoJointFrame: stereoJointFrame,
            conditionedStereoFrame: conditionedStereoFrame,
            jointDepthEvidenceFrame: jointDepthEvidenceFrame,
            disparityPreviewFrame: disparityPreviewFrame,
            fusedStereoTargetFrame: fusedStereoTargetFrame,
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
            liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
            liveRotationOverridesActive: liveRotationOverridesActive,
            liveRigPoseSource: liveRigPoseSource,
            skin3DApplyRevision: skin3DApplyRevision,
            skin3DViewportRefreshRevision: skin3DViewportRefreshRevision,
            vision3DSkinningAlignmentState: vision3DSkinningAlignmentState,
            viewportRefreshRevision: viewportRefreshRevision,
            rotationOverrideRevision: rotationOverrideRevision,
            rotationKeyRevision: rotationKeyRevision,
            selectedJointRotationFieldRevision: selectedJointRotationFieldRevision,
            spatialDepthControlRevision: spatialDepthControlRevision,
            spatialCameraOffsetRevision: spatialCameraOffsetRevision,
            spatialSolveTriggerRevision: spatialSolveTriggerRevision,
            visibilityToggleRevision: visibilityToggleRevision,
            solveInputRevision: solveInputRevision,
            disparityProgressRevision: disparityProgressRevision,
            lastViewportRefreshReason: lastViewportRefreshReason,
            showRawVision: showRawVision,
            showNormalizedMeshy: showNormalizedMeshy,
            showVision3DSkeleton: showVision3DSkeleton,
            showVision3DProjectionOverlay: showVision3DProjectionOverlay,
            showRightEyeVisionOverlay: showRightEyeVisionOverlay,
            showRightEyeNormalizedOverlay: showRightEyeNormalizedOverlay,
            showSmoothedMeshy: showSmoothedMeshy,
            showStereo3DSkeleton: showStereo3DSkeleton,
            showConditionedStereoSkeleton: showConditionedStereoSkeleton,
            showStereoReprojectionOverlay: showStereoReprojectionOverlay,
            showJointDepthValidationOverlay: showJointDepthValidationOverlay,
            showDisparityOnImagePlane: showDisparityOnImagePlane,
            selectedDisparityPlateOverlay: selectedDisparityPlateOverlay,
            disparityPlateOverlayOpacity: disparityPlateOverlayOpacity,
            showFusedStereoTargets: showFusedStereoTargets,
            showSpatialTargetBalls: showSpatialTargetBalls,
            spatialTargetBallScale: spatialTargetBallScale,
            showGroundPlane: showGroundPlane,
            showVisionRays: showVisionRays,
            showRaySolvedRig: showRaySolvedRig,
            showSkinnedRig: showSkinnedRig,
            showSkinnedGeometry: showSkinnedGeometry,
            showRotationGizmo: showRotationGizmo,
            stereoMetersToRigSceneUnits: stereoMetersToRigSceneUnits,
            stereoToRigAlignment: stereoToRigAlignment,
            solveTargetMode: solveTargetMode,
            spatialRayPinDepthMode: spatialRayPinDepthMode,
            spatialRayPinDepthFitSettings: spatialRayPinDepthFitSettings,
            autoSpatialDepthFitEnabled: autoSpatialDepthFitEnabled,
            manualSpatialCameraPanX: manualSpatialCameraPanX,
            manualSpatialCameraPanY: manualSpatialCameraPanY,
            manualSpatialCameraDepthZ: manualSpatialCameraDepthZ,
            rotationGizmoSpace: rotationGizmoSpace,
            selectedRotationJoint: selectedRotationJoint
        )
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let videoPlaneNode = SCNNode()
        private let disparityPlateOverlayNode = SCNNode()
        private let rawOverlayRoot = SCNNode()
        private let normalizedOverlayRoot = SCNNode()
        private let vision3DSkeletonRoot = SCNNode()
        private let vision3DProjectionOverlayRoot = SCNNode()
        private let rightRawOverlayRoot = SCNNode()
        private let rightNormalizedOverlayRoot = SCNNode()
        private let smoothedOverlayRoot = SCNNode()
        private let stereoSkeletonRoot = SCNNode()
        private let conditionedStereoSkeletonRoot = SCNNode()
        private let stereoReprojectionRoot = SCNNode()
        private let jointDepthEvidenceOverlayRoot = SCNNode()
        private let fusedStereoTargetRoot = SCNNode()
        private let alignedStereoTargetRoot = SCNNode()
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
        var onSpatialSolveTrace: ((SpatialSolveTrace) -> Void)?
        var onSpatialDepthFitReadback: ((
            _ autoZoom: Double,
            _ autoOffset: Double,
            _ score: Double,
            _ residual: Double
        ) -> Void)?

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
        private var liveRotationPreviewFrameIndexByJoint: [String: Int] = [:]
        private var activeGizmoAxis: ViewportJointRotationGizmo.Axis?
        private var activeGizmoJoint: String?
        private var activeGizmoPivotWorld: SIMD3<Float>?
        private var activeGizmoAxisWorld: SIMD3<Float>?
        private var activeGizmoStartVectorWorld: SIMD3<Float>?
        private var activeGizmoStartEuler: SIMD3<Float>?
        private var showRotationGizmo = false
        private var lastRotationGizmoVisibilitySignature: String?
        private var lastRotationOverrideLogSignature: String?
        private var currentDisparityOverlaySignature: String?
        private var lastFrameApplicationSignature: FrameApplicationSignature?
        private var lastSpatialSolveSignature: SpatialSolveSignature?
        private var lastSkin3DApplyRevision: Int = -1

        private struct FrameApplicationSignature: Equatable {
            let frameIndex: Int
            let timeSecondsRounded: Int
            let solveTargetMode: String
            let depthMode: String
            let viewportRefreshRevision: Int
            let rotationOverrideRevision: Int
            let rotationKeyRevision: Int
            let selectedJointRotationFieldRevision: Int
            let spatialDepthControlRevision: Int
            let spatialCameraOffsetRevision: Int
            let spatialSolveTriggerRevision: Int
            let visibilityToggleRevision: Int
            let solveInputRevision: Int
            let showSkinnedRig: Bool
            let showSkinnedGeometry: Bool
            let panXRounded: Int
            let panYRounded: Int
            let depthZRounded: Int
            let autoDepthFitEnabled: Bool
            let liveRigPoseSource: String
            let skin3DApplyRevision: Int
            let skin3DViewportRefreshRevision: Int
            let vision3DFrameIndex: Int?
            let vision3DAlignmentValid: Bool
            let vision3DAlignmentScaleRounded: Int
        }

        private struct SpatialSolveSignature: Equatable {
            let frameIndex: Int
            let timeMilliseconds: Int
            let solveTargetMode: String
            let depthMode: String
            let autoDepthFitEnabled: Bool
            let panXRounded: Int
            let panYRounded: Int
            let depthZRounded: Int
            let spatialDepthControlRevision: Int
            let spatialCameraOffsetRevision: Int
            let spatialSolveTriggerRevision: Int
            let viewportRefreshRevision: Int
            let evidenceFrameIndex: Int?
        }

        func makeView() -> SCNView {
            let view = RotoSCNView()

            view.scene = scene
            view.backgroundColor = .black
            view.allowsCameraControl = false
            view.autoenablesDefaultLighting = false
            view.rendersContinuously = false
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
            vision3DSkeletonRoot.name = "Vision3DSkeletonRoot"
            vision3DProjectionOverlayRoot.name = "Vision3DProjectionOverlayRoot"
            rightRawOverlayRoot.name = "RightEyeRawVisionOverlayRoot"
            rightNormalizedOverlayRoot.name = "RightEyeNormalizedMeshyOverlayRoot"
            smoothedOverlayRoot.name = "SmoothedMeshyOverlayRoot"
            stereoSkeletonRoot.name = "Stereo3DSkeletonRoot"
            conditionedStereoSkeletonRoot.name = "ConditionedStereoSkeletonRoot"
            stereoReprojectionRoot.name = "StereoReprojectionOverlayRoot"
            jointDepthEvidenceOverlayRoot.name = "JointDepthEvidenceOverlayRoot"
            disparityPlateOverlayNode.name = "DisparityPlateOverlayNode"
            fusedStereoTargetRoot.name = "FusedStereoTargetRoot"
            alignedStereoTargetRoot.name = "AlignedStereoTargetRoot"
            groundRoot.name = "GroundPlaneRoot"
            visionRayRoot.name = "VisionRayRoot"
            solvedRigRoot.name = "RaySolvedRigRoot"
            solveErrorRoot.name = "RaySolveErrorRoot"
            rigBoundsRoot.name = "ReferenceRigBoundsRoot"

            scene.rootNode.addChildNode(groundRoot)
            scene.rootNode.addChildNode(rawOverlayRoot)
            scene.rootNode.addChildNode(normalizedOverlayRoot)
            scene.rootNode.addChildNode(vision3DSkeletonRoot)
            scene.rootNode.addChildNode(vision3DProjectionOverlayRoot)
            scene.rootNode.addChildNode(rightRawOverlayRoot)
            scene.rootNode.addChildNode(rightNormalizedOverlayRoot)
            scene.rootNode.addChildNode(smoothedOverlayRoot)
            scene.rootNode.addChildNode(stereoSkeletonRoot)
            scene.rootNode.addChildNode(conditionedStereoSkeletonRoot)
            scene.rootNode.addChildNode(stereoReprojectionRoot)
            scene.rootNode.addChildNode(jointDepthEvidenceOverlayRoot)
            scene.rootNode.addChildNode(disparityPlateOverlayNode)
            scene.rootNode.addChildNode(fusedStereoTargetRoot)
            scene.rootNode.addChildNode(alignedStereoTargetRoot)
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
            vision3DFrame: NormalizedVision3DMeshyCapture.Frame?,
            rightRawFrame: RawVisionPoseCapture.PoseFrame?,
            rightNormalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            smoothedFrame: SmoothedMeshyPoseCapture.Frame?,
            stereoJointFrame: StereoMeshyJointCapture.Frame?,
            conditionedStereoFrame: ConditionedStereoJointCapture.Frame?,
            jointDepthEvidenceFrame: JointDepthEvidenceCapture.Frame?,
            disparityPreviewFrame: SpatialDisparityPreviewCapture.Frame?,
            fusedStereoTargetFrame: FusedStereoJointTargetCapture.Frame?,
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
            liveRotationPreviewFrameIndexByJoint: [String: Int],
            liveRotationOverridesActive: Bool,
            liveRigPoseSource: LiveRigPoseSource,
            skin3DApplyRevision: Int,
            skin3DViewportRefreshRevision: Int,
            vision3DSkinningAlignmentState: Vision3DSkinningAlignmentState,
            viewportRefreshRevision: Int,
            rotationOverrideRevision: Int,
            rotationKeyRevision: Int,
            selectedJointRotationFieldRevision: Int,
            spatialDepthControlRevision: Int,
            spatialCameraOffsetRevision: Int,
            spatialSolveTriggerRevision: Int,
            visibilityToggleRevision: Int,
            solveInputRevision: Int,
            disparityProgressRevision: Int,
            lastViewportRefreshReason: String,
            showRawVision: Bool,
            showNormalizedMeshy: Bool,
            showVision3DSkeleton: Bool,
            showVision3DProjectionOverlay: Bool,
            showRightEyeVisionOverlay: Bool,
            showRightEyeNormalizedOverlay: Bool,
            showSmoothedMeshy: Bool,
            showStereo3DSkeleton: Bool,
            showConditionedStereoSkeleton: Bool,
            showStereoReprojectionOverlay: Bool,
            showJointDepthValidationOverlay: Bool,
            showDisparityOnImagePlane: Bool,
            selectedDisparityPlateOverlay: DisparityPlateOverlayKind,
            disparityPlateOverlayOpacity: Double,
            showFusedStereoTargets: Bool,
            showSpatialTargetBalls: Bool,
            spatialTargetBallScale: Double,
            showGroundPlane: Bool,
            showVisionRays: Bool,
            showRaySolvedRig: Bool,
            showSkinnedRig: Bool,
            showSkinnedGeometry: Bool,
            showRotationGizmo: Bool,
            stereoMetersToRigSceneUnits: Float,
            stereoToRigAlignment: StereoToRigAlignment,
            solveTargetMode: RotoSolveTargetMode,
            spatialRayPinDepthMode: SpatialRayPinDepthMode,
            spatialRayPinDepthFitSettings: SpatialRayPinDepthFitSettings,
            autoSpatialDepthFitEnabled: Bool,
            manualSpatialCameraPanX: Double,
            manualSpatialCameraPanY: Double,
            manualSpatialCameraDepthZ: Double,
            rotationGizmoSpace: RotationGizmoSpace,
            selectedRotationJoint: String
        ) {
            self.selectedRotationJoint = selectedRotationJoint
            self.currentSkinnedRigSession = skinnedRigSession
            self.heldRotationOverrideEulerXYZByJoint = heldRotationOverrideEulerXYZByJoint
            self.liveRotationOverrideEulerXYZByJoint = liveRotationOverrideEulerXYZByJoint
            self.liveRotationPreviewFrameIndexByJoint = liveRotationPreviewFrameIndexByJoint
            self.showRotationGizmo = showRotationGizmo
            _ = disparityProgressRevision

            view.allowsCameraControl = false
            view.pointOfView = cameraNode

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            defer {
                SCNTransaction.commit()
                view.isPlaying = true
                view.rendersContinuously = false
                view.setNeedsDisplay(view.bounds)
                view.needsDisplay = true
            }

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

            let frameApplicationSignature = FrameApplicationSignature(
                frameIndex: frameIndex,
                timeSecondsRounded: Int(((normalizedFrame?.timeSeconds ?? Double(frameIndex)) * 1000).rounded()),
                solveTargetMode: solveTargetMode.rawValue,
                depthMode: spatialRayPinDepthMode.rawValue,
                viewportRefreshRevision: viewportRefreshRevision,
                rotationOverrideRevision: rotationOverrideRevision,
                rotationKeyRevision: rotationKeyRevision,
                selectedJointRotationFieldRevision: selectedJointRotationFieldRevision,
                spatialDepthControlRevision: spatialDepthControlRevision,
                spatialCameraOffsetRevision: spatialCameraOffsetRevision,
                spatialSolveTriggerRevision: spatialSolveTriggerRevision,
                visibilityToggleRevision: visibilityToggleRevision,
                solveInputRevision: solveInputRevision,
                showSkinnedRig: showSkinnedRig,
                showSkinnedGeometry: showSkinnedGeometry,
                panXRounded: Int((manualSpatialCameraPanX * 10000).rounded()),
                panYRounded: Int((manualSpatialCameraPanY * 10000).rounded()),
                depthZRounded: Int((manualSpatialCameraDepthZ * 10000).rounded()),
                autoDepthFitEnabled: autoSpatialDepthFitEnabled,
                liveRigPoseSource: liveRigPoseSource.rawValue,
                skin3DApplyRevision: skin3DApplyRevision,
                skin3DViewportRefreshRevision: skin3DViewportRefreshRevision,
                vision3DFrameIndex: vision3DFrame?.frameIndex,
                vision3DAlignmentValid: vision3DSkinningAlignmentState.valid,
                vision3DAlignmentScaleRounded: Int((vision3DSkinningAlignmentState.scale * 10000).rounded())
            )
            let previousFrameApplicationSignature = lastFrameApplicationSignature
            let mustReapplyFrame = frameApplicationSignature != previousFrameApplicationSignature

            if mustReapplyFrame,
               let previousFrameApplicationSignature,
               previousFrameApplicationSignature.frameIndex == frameApplicationSignature.frameIndex {
                print("""
                [RotoSceneVideoViewport] static frame recompute
                  frame: \(frameIndex)
                  reason: \(lastViewportRefreshReason)
                  viewportRefreshRevision: \(viewportRefreshRevision)
                  rotationOverrideRevision: \(rotationOverrideRevision)
                  rotationKeyRevision: \(rotationKeyRevision)
                  selectedJointRotationFieldRevision: \(selectedJointRotationFieldRevision)
                  spatialDepthControlRevision: \(spatialDepthControlRevision)
                  spatialCameraOffsetRevision: \(spatialCameraOffsetRevision)
                  spatialSolveTriggerRevision: \(spatialSolveTriggerRevision)
                  visibilityToggleRevision: \(visibilityToggleRevision)
                """)

                if previousFrameApplicationSignature.rotationOverrideRevision != frameApplicationSignature.rotationOverrideRevision ||
                    previousFrameApplicationSignature.rotationKeyRevision != frameApplicationSignature.rotationKeyRevision ||
                    previousFrameApplicationSignature.selectedJointRotationFieldRevision != frameApplicationSignature.selectedJointRotationFieldRevision {
                    print("""
                    [RotoSceneVideoViewport] rotation authoring static-frame refresh
                      frame: \(frameIndex)
                      viewportRefreshRevision: \(viewportRefreshRevision)
                      rotationOverrideRevision: \(rotationOverrideRevision)
                      rotationKeyRevision: \(rotationKeyRevision)
                      selectedJointRotationFieldRevision: \(selectedJointRotationFieldRevision)
                    """)
                }
            }

            updateGroundPlane(groundPlane: groundPlane, visible: showGroundPlane)
            updateSkinnedRig(
                view: view,
                session: skinnedRigSession,
                frame: raySolvedFrame,
                frameIndex: frameIndex,
                normalizedFrame: normalizedFrame,
                vision3DFrame: vision3DFrame,
                rightNormalizedFrame: rightNormalizedFrame,
                jointDepthEvidenceFrame: jointDepthEvidenceFrame,
                conditionedStereoFrame: conditionedStereoFrame,
                fusedStereoTargetFrame: fusedStereoTargetFrame,
                liveRigPoseSource: liveRigPoseSource,
                skin3DApplyRevision: skin3DApplyRevision,
                skin3DViewportRefreshRevision: skin3DViewportRefreshRevision,
                vision3DSkinningAlignmentState: vision3DSkinningAlignmentState,
                solveTargetMode: solveTargetMode,
                spatialRayPinDepthMode: spatialRayPinDepthMode,
                spatialRayPinDepthFitSettings: spatialRayPinDepthFitSettings,
                autoSpatialDepthFitEnabled: autoSpatialDepthFitEnabled,
                manualSpatialCameraPanX: manualSpatialCameraPanX,
                manualSpatialCameraPanY: manualSpatialCameraPanY,
                manualSpatialCameraDepthZ: manualSpatialCameraDepthZ,
                spatialCameraOffsetRevision: spatialCameraOffsetRevision,
                spatialDepthControlRevision: spatialDepthControlRevision,
                spatialSolveTriggerRevision: spatialSolveTriggerRevision,
                viewportRefreshRevision: viewportRefreshRevision,
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
                liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
                liveRotationOverridesActive: liveRotationOverridesActive,
                visible: showSkinnedRig,
                showSkinnedGeometry: showSkinnedGeometry,
                stereoToRigAlignment: stereoToRigAlignment
            )
            lastFrameApplicationSignature = frameApplicationSignature
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
            updateVision3DSkeleton(
                vision3DFrame,
                visible: showVision3DSkeleton
            )
            updateVision3DProjectionOverlay(
                vision3DFrame,
                visible: showVision3DProjectionOverlay
            )
            updateRightRawVisionOverlay(
                rightRawFrame,
                visible: showRightEyeVisionOverlay
            )
            updateRightNormalizedOverlay(
                rightNormalizedFrame,
                visible: showRightEyeNormalizedOverlay
            )
            updateSmoothedOverlay(smoothedFrame, visible: showSmoothedMeshy)
            updateDisparityPlateOverlay(
                previewFrame: disparityPreviewFrame,
                visible: showDisparityOnImagePlane,
                kind: selectedDisparityPlateOverlay,
                opacity: disparityPlateOverlayOpacity
            )
            updateStereoDepthOverlay(
                stereoJointFrame,
                visible: showStereo3DSkeleton,
                metersToRigSceneUnits: stereoMetersToRigSceneUnits
            )
            updateConditionedStereoSkeleton(
                frame: conditionedStereoFrame,
                visible: showConditionedStereoSkeleton,
                metersToRigSceneUnits: stereoMetersToRigSceneUnits
            )
            updateStereoReprojectionOverlay(
                stereoJointFrame,
                visible: showStereoReprojectionOverlay
            )
            updateJointDepthEvidenceOverlay(
                evidenceFrame: jointDepthEvidenceFrame,
                normalizedFrame: normalizedFrame,
                visible: showJointDepthValidationOverlay
            )
            updateFusedStereoTargetOverlay(
                frame: fusedStereoTargetFrame,
                visible: showFusedStereoTargets,
                metersToRigSceneUnits: stereoMetersToRigSceneUnits
            )
            updateAlignedStereoTargetOverlay(
                conditionedFrame: conditionedStereoFrame,
                fusedFrame: fusedStereoTargetFrame,
                solveTargetMode: solveTargetMode,
                alignment: stereoToRigAlignment,
                visible: showSpatialTargetBalls && stereoToRigAlignment.isValid,
                scale: spatialTargetBallScale
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
                  verticalFOV: \(String(format: "%.3f", cameraFOVDegrees))
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

        private func pointOnCurrentVideoPlane(
            x: Double,
            y: Double,
            zOffsetTowardCamera: Float
        ) -> SIMD3<Float> {
            pointOnCurrentImagePlane(
                x: x,
                y: y,
                zOffsetTowardCamera: zOffsetTowardCamera
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

        private func updateVision3DSkeleton(
            _ frame: NormalizedVision3DMeshyCapture.Frame?,
            visible: Bool
        ) {
            vision3DSkeletonRoot.isHidden = !visible
            removeAllChildren(from: vision3DSkeletonRoot)

            guard visible,
                  let frame,
                  let hips = frame.joints["Hips"],
                  hips.confidence > 0 else {
                return
            }

            let rootOnPlate: SIMD3<Float>

            if let projectedX = hips.projectedX,
               let projectedY = hips.projectedY {
                rootOnPlate = pointOnCurrentVideoPlane(
                    x: projectedX,
                    y: projectedY,
                    zOffsetTowardCamera: 1.55
                )
            } else {
                rootOnPlate = SIMD3<Float>(
                    0,
                    -Float(videoPlaneSize.height) * 0.18,
                    currentVideoPlaneZ + 1.55
                )
            }

            let rootMeters = SIMD3<Float>(
                Float(hips.x),
                Float(hips.y),
                Float(hips.z)
            )
            let scale = Float(max(videoPlaneSize.width, videoPlaneSize.height)) * 0.28
            let color = NSColor.systemPurple
            var positions: [String: SIMD3<Float>] = [:]

            for (jointName, joint) in frame.joints where joint.confidence > 0 {
                let meters = SIMD3<Float>(
                    Float(joint.x),
                    Float(joint.y),
                    Float(joint.z)
                )
                let local = meters - rootMeters
                positions[jointName] = rootOnPlate + SIMD3<Float>(
                    local.x * scale,
                    local.y * scale,
                    -local.z * scale
                )
            }

            var boneCount = 0

            for (a, b) in meshySkeletonBones {
                guard let pa = positions[a],
                      let pb = positions[b] else {
                    continue
                }

                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: color.withAlphaComponent(0.85)
                )
                line.renderingOrder = 1080
                vision3DSkeletonRoot.addChildNode(line)
                boneCount += 1
            }

            var jointCount = 0

            for (_, position) in positions {
                let node = makePointNode(
                    color: color.withAlphaComponent(0.9),
                    radius: currentRawVisionPointRadius() * 0.9
                )
                node.simdPosition = position
                node.renderingOrder = 1090
                vision3DSkeletonRoot.addChildNode(node)
                jointCount += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Vision 3D skeleton updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(jointCount)
                  bonesDrawn: \(boneCount)
                  anchoredToProjectedHips: \(hips.projectedX != nil && hips.projectedY != nil)
                """)
            }
        }

        private func updateVision3DProjectionOverlay(
            _ frame: NormalizedVision3DMeshyCapture.Frame?,
            visible: Bool
        ) {
            vision3DProjectionOverlayRoot.isHidden = !visible
            removeAllChildren(from: vision3DProjectionOverlayRoot)

            guard visible,
                  let frame else {
                return
            }

            var jointCount = 0

            for (_, joint) in frame.joints {
                guard joint.confidence > 0,
                      let x = joint.projectedX,
                      let y = joint.projectedY else {
                    continue
                }

                let p = pointOnCurrentVideoPlane(
                    x: x,
                    y: y,
                    zOffsetTowardCamera: 1.62
                )
                let node = makePointNode(
                    color: NSColor.systemBlue.withAlphaComponent(0.9),
                    radius: currentRawVisionPointRadius() * 0.75
                )

                node.simdPosition = p
                node.renderingOrder = 1100
                vision3DProjectionOverlayRoot.addChildNode(node)
                jointCount += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Vision 3D projection overlay updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(jointCount)
                """)
            }
        }

        private func updateRightRawVisionOverlay(
            _ frame: RawVisionPoseCapture.PoseFrame?,
            visible: Bool
        ) {
            rightRawOverlayRoot.isHidden = !visible
            removeAllChildren(from: rightRawOverlayRoot)

            guard visible, let frame else {
                return
            }

            var count = 0

            for (_, joint) in frame.joints {
                let p = pointOnCurrentVideoPlane(
                    x: joint.x,
                    y: joint.y,
                    zOffsetTowardCamera: 0.85
                )
                let node = makePointNode(
                    color: NSColor.systemPink.withAlphaComponent(
                        CGFloat(max(0.25, min(joint.confidence, 1.0)))
                    ),
                    radius: currentRawVisionPointRadius()
                )

                node.simdPosition = p
                node.renderingOrder = 900
                rightRawOverlayRoot.addChildNode(node)
                count += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Right-eye raw Vision overlay updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(count)
                """)
            }
        }

        private func updateRightNormalizedOverlay(
            _ frame: NormalizedMeshyPoseCapture.Frame?,
            visible: Bool
        ) {
            rightNormalizedOverlayRoot.isHidden = !visible
            removeAllChildren(from: rightNormalizedOverlayRoot)

            guard visible, let frame else {
                return
            }

            var jointCount = 0
            var boneCount = 0
            let color = NSColor.systemCyan

            for (a, b) in meshySkeletonBones {
                guard let ja = frame.joints[a],
                      let jb = frame.joints[b],
                      !ja.missing,
                      !jb.missing else {
                    continue
                }

                let pa = pointOnCurrentVideoPlane(
                    x: ja.x,
                    y: ja.y,
                    zOffsetTowardCamera: 0.92
                )
                let pb = pointOnCurrentVideoPlane(
                    x: jb.x,
                    y: jb.y,
                    zOffsetTowardCamera: 0.92
                )
                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: color.withAlphaComponent(0.9)
                )

                line.renderingOrder = 910
                rightNormalizedOverlayRoot.addChildNode(line)
                boneCount += 1
            }

            for (_, joint) in frame.joints where !joint.missing {
                let p = pointOnCurrentVideoPlane(
                    x: joint.x,
                    y: joint.y,
                    zOffsetTowardCamera: 0.95
                )
                let node = makePointNode(
                    color: joint.generated
                        ? color.withAlphaComponent(0.35)
                        : color,
                    radius: currentRawVisionPointRadius()
                )

                node.simdPosition = p
                node.renderingOrder = 920
                rightNormalizedOverlayRoot.addChildNode(node)
                jointCount += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Right-eye normalized Meshy24 overlay updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(jointCount)
                  bonesDrawn: \(boneCount)
                """)
            }
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

        private func updateDisparityPlateOverlay(
            previewFrame: SpatialDisparityPreviewCapture.Frame?,
            visible: Bool,
            kind: DisparityPlateOverlayKind,
            opacity: Double
        ) {
            guard visible,
                  let previewFrame else {
                disparityPlateOverlayNode.isHidden = true
                currentDisparityOverlaySignature = nil
                return
            }

            let path: String?

            switch kind {
            case .depth:
                path = previewFrame.depthPreviewPNGPath
            case .confidence:
                path = previewFrame.confidencePreviewPNGPath
            case .rawDisparity:
                path = previewFrame.rawDisparityPreviewPNGPath
            }

            guard let path,
                  FileManager.default.fileExists(atPath: path),
                  let image = NSImage(contentsOfFile: path) else {
                disparityPlateOverlayNode.isHidden = true
                currentDisparityOverlaySignature = nil
                return
            }

            if disparityPlateOverlayNode.geometry == nil {
                disparityPlateOverlayNode.geometry = SCNPlane(
                    width: videoPlaneSize.width,
                    height: videoPlaneSize.height
                )
            }

            if let plane = disparityPlateOverlayNode.geometry as? SCNPlane {
                plane.width = videoPlaneSize.width
                plane.height = videoPlaneSize.height
            }

            disparityPlateOverlayNode.simdPosition = SIMD3<Float>(
                0,
                0,
                currentVideoPlaneZ + 1.35
            )
            disparityPlateOverlayNode.renderingOrder = 700
            disparityPlateOverlayNode.isHidden = false

            let clampedOpacity = max(0, min(1, opacity))
            let signature = "\(path)|\(kind.rawValue)|\(String(format: "%.3f", clampedOpacity))|\(videoPlaneSize.width)x\(videoPlaneSize.height)"

            guard currentDisparityOverlaySignature != signature else {
                return
            }

            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.transparency = CGFloat(clampedOpacity)
            material.isDoubleSided = true
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.contentsTransform = SCNMatrix4Identity

            disparityPlateOverlayNode.geometry?.materials = [material]
            currentDisparityOverlaySignature = signature

            print("""
            [RotoSceneVideoViewport] Disparity plate overlay updated
              frame: \(previewFrame.frameIndex)
              kind: \(kind.rawValue)
              path: \(path)
              opacity: \(clampedOpacity)
              normalizedUV: 0..1
            """)
        }

        private func updateStereoDepthOverlay(
            _ frame: StereoMeshyJointCapture.Frame?,
            visible: Bool,
            metersToRigSceneUnits: Float
        ) {
            stereoSkeletonRoot.isHidden = !visible
            removeAllChildren(from: stereoSkeletonRoot)

            guard visible, let frame else {
                return
            }

            let scale = max(metersToRigSceneUnits, 0.0001)
            var positions: [String: SIMD3<Float>] = [:]

            for (name, joint) in frame.joints where joint.validStereo && joint.positionCameraXYZ.count == 3 {
                positions[name] = SIMD3<Float>(
                    Float(joint.positionCameraXYZ[0]) * scale,
                    Float(joint.positionCameraXYZ[1]) * scale,
                    Float(joint.positionCameraXYZ[2]) * scale
                )
            }

            let color = NSColor.systemCyan

            for (a, b) in meshySkeletonBones {
                guard let pa = positions[a],
                      let pb = positions[b] else {
                    continue
                }

                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: color.withAlphaComponent(0.9)
                )
                line.renderingOrder = 799
                stereoSkeletonRoot.addChildNode(line)
            }

            var drawn = 0

            for (_, p) in positions {
                let node = makePointNode(
                    color: color,
                    radius: 0.025
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 800
                stereoSkeletonRoot.addChildNode(node)
                drawn += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Stereo 3D skeleton updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(drawn)
                """)
            }
        }

        private func updateStereoReprojectionOverlay(
            _ frame: StereoMeshyJointCapture.Frame?,
            visible: Bool
        ) {
            stereoReprojectionRoot.isHidden = !visible
            removeAllChildren(from: stereoReprojectionRoot)

            guard visible, let frame else {
                return
            }

            var count = 0

            for (_, joint) in frame.joints where joint.validStereo {
                let p = pointOnCurrentVideoPlane(
                    x: joint.reprojectedLeftX,
                    y: joint.reprojectedLeftY,
                    zOffsetTowardCamera: 1.10
                )
                let node = makePointNode(
                    color: NSColor.systemCyan,
                    radius: currentRawVisionPointRadius() * 0.85
                )

                node.simdPosition = p
                node.renderingOrder = 960
                stereoReprojectionRoot.addChildNode(node)
                count += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Stereo reprojection overlay updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(count)
                """)
            }
        }

        private func updateJointDepthEvidenceOverlay(
            evidenceFrame: JointDepthEvidenceCapture.Frame?,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            visible: Bool
        ) {
            jointDepthEvidenceOverlayRoot.isHidden = !visible
            removeAllChildren(from: jointDepthEvidenceOverlayRoot)

            guard visible,
                  let evidenceFrame,
                  let normalizedFrame else {
                return
            }

            var drawn = 0
            var pass = 0
            var fail = 0
            var noSample = 0

            for (jointName, evidence) in evidenceFrame.joints {
                guard let joint = normalizedFrame.joints[jointName],
                      !joint.missing else {
                    continue
                }

                let color: NSColor

                if evidence.disparityDepthMeters == nil {
                    color = .systemGray
                    noSample += 1
                } else if evidence.passesDepthValidation {
                    color = .systemGreen
                    pass += 1
                } else {
                    color = .systemRed
                    fail += 1
                }

                let p = pointOnCurrentVideoPlane(
                    x: joint.x,
                    y: joint.y,
                    zOffsetTowardCamera: 1.15
                )
                let node = makePointNode(
                    color: color,
                    radius: currentRawVisionPointRadius() * 1.35
                )

                node.simdPosition = p
                node.renderingOrder = 980
                jointDepthEvidenceOverlayRoot.addChildNode(node)
                drawn += 1
            }

            if evidenceFrame.frameIndex == 0 || evidenceFrame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Joint depth validation overlay updated
                  frame: \(evidenceFrame.frameIndex)
                  jointsDrawn: \(drawn)
                  pass: \(pass)
                  fail: \(fail)
                  noSample: \(noSample)
                """)
            }
        }

        private func updateConditionedStereoSkeleton(
            frame: ConditionedStereoJointCapture.Frame?,
            visible: Bool,
            metersToRigSceneUnits: Float
        ) {
            conditionedStereoSkeletonRoot.isHidden = !visible
            removeAllChildren(from: conditionedStereoSkeletonRoot)

            guard visible, let frame else {
                return
            }

            let scale = max(metersToRigSceneUnits, 0.0001)
            var positions: [String: SIMD3<Float>] = [:]

            for (name, joint) in frame.joints where joint.positionCameraXYZ.count == 3 {
                positions[name] = SIMD3<Float>(
                    Float(joint.positionCameraXYZ[0]) * scale,
                    Float(joint.positionCameraXYZ[1]) * scale,
                    Float(joint.positionCameraXYZ[2]) * scale
                )
            }

            let color = NSColor.systemMint

            for (a, b) in meshySkeletonBones {
                guard let pa = positions[a],
                      let pb = positions[b] else {
                    continue
                }

                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: color.withAlphaComponent(0.95)
                )
                line.renderingOrder = 840
                conditionedStereoSkeletonRoot.addChildNode(line)
            }

            var drawn = 0

            for (_, p) in positions {
                let node = makePointNode(
                    color: color,
                    radius: 0.03
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 850
                conditionedStereoSkeletonRoot.addChildNode(node)
                drawn += 1
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Conditioned stereo skeleton updated
                  frame: \(frame.frameIndex)
                  jointsDrawn: \(drawn)
                """)
            }
        }

        private func updateFusedStereoTargetOverlay(
            frame: FusedStereoJointTargetCapture.Frame?,
            visible: Bool,
            metersToRigSceneUnits: Float
        ) {
            fusedStereoTargetRoot.isHidden = !visible
            removeAllChildren(from: fusedStereoTargetRoot)

            guard visible, let frame else {
                return
            }

            let scale = max(metersToRigSceneUnits, 0.0001)
            var positions: [String: SIMD3<Float>] = [:]
            var accepted = 0
            var rejected = 0
            var held = 0

            for (name, target) in frame.joints {
                let point = target.positionCameraXYZ ?? target.visionStereoPositionCameraXYZ

                guard let point,
                      point.count == 3 else {
                    continue
                }

                let p = SIMD3<Float>(
                    Float(point[0]),
                    Float(point[1]),
                    Float(point[2])
                ) * scale
                positions[name] = p

                let color: NSColor

                if target.rejected {
                    color = .systemRed
                    rejected += 1
                } else if target.status.contains("held") {
                    color = .systemGray
                    held += 1
                } else {
                    color = .systemGreen
                    accepted += 1
                }

                let node = makePointNode(
                    color: color,
                    radius: target.rejected ? 0.045 : 0.035
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 875
                fusedStereoTargetRoot.addChildNode(node)
            }

            for (a, b) in meshySkeletonBones {
                guard let targetA = frame.joints[a],
                      let targetB = frame.joints[b],
                      !targetA.rejected,
                      !targetB.rejected,
                      let pa = positions[a],
                      let pb = positions[b] else {
                    continue
                }

                let color = targetA.status.contains("held") || targetB.status.contains("held")
                    ? NSColor.systemGray.withAlphaComponent(0.85)
                    : NSColor.systemGreen.withAlphaComponent(0.95)
                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: color
                )
                line.renderingOrder = 870
                fusedStereoTargetRoot.addChildNode(line)
            }

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Fused stereo target overlay updated
                  frame: \(frame.frameIndex)
                  accepted: \(accepted)
                  held: \(held)
                  rejected: \(rejected)
                """)
            }
        }

        private func updateAlignedStereoTargetOverlay(
            conditionedFrame: ConditionedStereoJointCapture.Frame?,
            fusedFrame: FusedStereoJointTargetCapture.Frame?,
            solveTargetMode: RotoSolveTargetMode,
            alignment: StereoToRigAlignment,
            visible: Bool,
            scale: Double
        ) {
            alignedStereoTargetRoot.isHidden = !visible
            removeAllChildren(from: alignedStereoTargetRoot)

            guard visible, alignment.isValid else {
                return
            }

            let snapshot = alignedTargetSnapshot(
                conditionedFrame: conditionedFrame,
                fusedFrame: fusedFrame,
                solveTargetMode: solveTargetMode,
                alignment: alignment
            )

            guard !snapshot.positions.isEmpty else {
                return
            }

            for (a, b) in meshySkeletonBones {
                guard snapshot.connectableJoints.contains(a),
                      snapshot.connectableJoints.contains(b),
                      let pa = snapshot.positions[a],
                      let pb = snapshot.positions[b] else {
                    continue
                }

                let line = makeLineNode(
                    from: SCNVector3(pa.x, pa.y, pa.z),
                    to: SCNVector3(pb.x, pb.y, pb.z),
                    color: NSColor.systemGreen.withAlphaComponent(0.55)
                )
                line.renderingOrder = 930
                alignedStereoTargetRoot.addChildNode(line)
            }

            for (jointName, p) in snapshot.positions {
                let status = snapshot.statusByJoint[jointName] ?? "accepted"
                let confidence = snapshot.confidenceByJoint[jointName] ?? 1.0
                let rejected = status.contains("rejected")
                let held = status.contains("held")
                let radius = 0.04 * CGFloat(max(0.15, min(1.0, scale)))

                let node = makePointNode(
                    color: spatialTargetColor(
                        confidence: confidence,
                        rejected: rejected,
                        held: held
                    ),
                    radius: radius
                )
                node.position = SCNVector3(p.x, p.y, p.z)
                node.renderingOrder = 940
                alignedStereoTargetRoot.addChildNode(node)
            }

            if snapshot.frameIndex == 0 || snapshot.frameIndex % 30 == 0 {
                print("""
                [RotoSceneVideoViewport] Aligned stereo target overlay updated
                  frame: \(snapshot.frameIndex)
                  mode: \(snapshot.source)
                  jointsDrawn: \(snapshot.positions.count)
                  alignmentScale: \(alignment.scale)
                  alignmentTranslation: \(alignment.translation.simdFloat)
                """)
            }
        }

        private struct AlignedTargetSnapshot {
            let frameIndex: Int
            let source: String
            let positions: [String: SIMD3<Float>]
            let connectableJoints: Set<String>
            let statusByJoint: [String: String]
            let confidenceByJoint: [String: Double]
        }

        private func spatialTargetColor(
            confidence: Double,
            rejected: Bool,
            held: Bool
        ) -> NSColor {
            if rejected {
                return NSColor.systemRed.withAlphaComponent(0.75)
            }

            if held {
                return NSColor.systemGray.withAlphaComponent(0.65)
            }

            let c = max(0.0, min(1.0, confidence))

            if c >= 0.65 {
                return NSColor.systemGreen.withAlphaComponent(0.70)
            }

            if c >= 0.35 {
                return NSColor.systemYellow.withAlphaComponent(0.70)
            }

            return NSColor.systemOrange.withAlphaComponent(0.70)
        }

        private func alignedTargetSnapshot(
            conditionedFrame: ConditionedStereoJointCapture.Frame?,
            fusedFrame: FusedStereoJointTargetCapture.Frame?,
            solveTargetMode: RotoSolveTargetMode,
            alignment: StereoToRigAlignment
        ) -> AlignedTargetSnapshot {
            if let fusedFrame {
                var positions: [String: SIMD3<Float>] = [:]
                var connectable = Set<String>()
                var statuses: [String: String] = [:]
                var confidences: [String: Double] = [:]

                for (jointName, target) in fusedFrame.joints {
                    let point = target.positionCameraXYZ ?? target.visionStereoPositionCameraXYZ

                    guard let point,
                          point.count == 3 else {
                        continue
                    }

                    let stereoMeters = SIMD3<Float>(
                        Float(point[0]),
                        Float(point[1]),
                        Float(point[2])
                    )
                    positions[jointName] = StereoToRigAlignmentSolver.transform(
                        stereoMeters,
                        alignment: alignment
                    )
                    statuses[jointName] = target.rejected
                        ? "rejected"
                        : target.status
                    confidences[jointName] = target.confidence

                    if !target.rejected {
                        connectable.insert(jointName)
                    }
                }

                return AlignedTargetSnapshot(
                    frameIndex: fusedFrame.frameIndex,
                    source: "fusedStereoTargets",
                    positions: positions,
                    connectableJoints: connectable,
                    statusByJoint: statuses,
                    confidenceByJoint: confidences
                )
            }

            guard let conditionedFrame else {
                return AlignedTargetSnapshot(
                    frameIndex: -1,
                    source: "none",
                    positions: [:],
                    connectableJoints: [],
                    statusByJoint: [:],
                    confidenceByJoint: [:]
                )
            }

            var positions: [String: SIMD3<Float>] = [:]
            var statuses: [String: String] = [:]
            var confidences: [String: Double] = [:]

            for (jointName, target) in conditionedFrame.joints {
                guard target.positionCameraXYZ.count == 3 else {
                    continue
                }

                let stereoMeters = SIMD3<Float>(
                    Float(target.positionCameraXYZ[0]),
                    Float(target.positionCameraXYZ[1]),
                    Float(target.positionCameraXYZ[2])
                )
                positions[jointName] = StereoToRigAlignmentSolver.transform(
                    stereoMeters,
                    alignment: alignment
                )
                statuses[jointName] = target.status
                confidences[jointName] = target.confidence
            }

            return AlignedTargetSnapshot(
                frameIndex: conditionedFrame.frameIndex,
                source: "conditionedStereoTargets",
                positions: positions,
                connectableJoints: Set(positions.keys),
                statusByJoint: statuses,
                confidenceByJoint: confidences
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

        private struct RigPoseSnapshot {
            let displayRootTransform: simd_float4x4
            let boneTransforms: [String: simd_float4x4]
        }

        private struct SpatialSolveVisibilityCheck {
            let accepted: Bool
            let reason: String
            let meshHidden: Bool
            let projectedOnScreen: Bool
            let projectedBounds: String
            let worldMin: SIMD3<Float>
            let worldMax: SIMD3<Float>
        }

        private func makeRigPoseSnapshot(
            session: SkinnedRigSession
        ) -> RigPoseSnapshot {
            var bones: [String: simd_float4x4] = [:]

            for jointName in session.jointOrder {
                if let bone = session.bonesByCanonicalName[jointName] {
                    bones[jointName] = bone.simdTransform
                }
            }

            return RigPoseSnapshot(
                displayRootTransform: session.displayRootNode.simdTransform,
                boneTransforms: bones
            )
        }

        private func restoreRigPoseSnapshot(
            _ snapshot: RigPoseSnapshot,
            session: SkinnedRigSession
        ) {
            session.displayRootNode.simdTransform = snapshot.displayRootTransform

            for (jointName, transform) in snapshot.boneTransforms {
                session.bonesByCanonicalName[jointName]?.simdTransform = transform
            }
        }

        private func checkSolvedRigVisibility(
            session: SkinnedRigSession,
            view: SCNView
        ) -> SpatialSolveVisibilityCheck {
            if session.displayRootNode.isHidden {
                return SpatialSolveVisibilityCheck(
                    accepted: false,
                    reason: "displayRootNode is hidden",
                    meshHidden: true,
                    projectedOnScreen: false,
                    projectedBounds: "hidden",
                    worldMin: SIMD3<Float>(0, 0, 0),
                    worldMax: SIMD3<Float>(0, 0, 0)
                )
            }

            if session.skinnedMeshNode.isHidden {
                return SpatialSolveVisibilityCheck(
                    accepted: false,
                    reason: "skinnedMeshNode is hidden",
                    meshHidden: true,
                    projectedOnScreen: false,
                    projectedBounds: "mesh hidden",
                    worldMin: SIMD3<Float>(0, 0, 0),
                    worldMax: SIMD3<Float>(0, 0, 0)
                )
            }

            guard rigTransformsAreFinite(session: session) else {
                return SpatialSolveVisibilityCheck(
                    accepted: false,
                    reason: "non-finite rig transform",
                    meshHidden: false,
                    projectedOnScreen: false,
                    projectedBounds: "non-finite transform",
                    worldMin: SIMD3<Float>(0, 0, 0),
                    worldMax: SIMD3<Float>(0, 0, 0)
                )
            }

            guard let bounds = worldBoundingBox(node: session.displayRootNode),
                  bounds.min.x.isFinite,
                  bounds.min.y.isFinite,
                  bounds.min.z.isFinite,
                  bounds.max.x.isFinite,
                  bounds.max.y.isFinite,
                  bounds.max.z.isFinite else {
                return SpatialSolveVisibilityCheck(
                    accepted: false,
                    reason: "invalid world bounds",
                    meshHidden: false,
                    projectedOnScreen: false,
                    projectedBounds: "invalid",
                    worldMin: SIMD3<Float>(0, 0, 0),
                    worldMax: SIMD3<Float>(0, 0, 0)
                )
            }

            let corners = [
                SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.min.z),
                SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.max.z),
                SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.min.z),
                SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.max.z),
                SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.min.z),
                SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.max.z),
                SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.min.z),
                SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.max.z)
            ]
            var projectedXs: [CGFloat] = []
            var projectedYs: [CGFloat] = []

            for corner in corners {
                let p = view.projectPoint(SCNVector3(corner.x, corner.y, corner.z))

                if p.x.isFinite,
                   p.y.isFinite,
                   p.z.isFinite {
                    projectedXs.append(CGFloat(p.x))
                    projectedYs.append(CGFloat(p.y))
                }
            }

            guard let minX = projectedXs.min(),
                  let maxX = projectedXs.max(),
                  let minY = projectedYs.min(),
                  let maxY = projectedYs.max() else {
                return SpatialSolveVisibilityCheck(
                    accepted: false,
                    reason: "projection failed",
                    meshHidden: false,
                    projectedOnScreen: false,
                    projectedBounds: "projection failed",
                    worldMin: bounds.min,
                    worldMax: bounds.max
                )
            }

            let viewRect = view.bounds.insetBy(
                dx: -view.bounds.width * 2,
                dy: -view.bounds.height * 2
            )
            let projectedRect = CGRect(
                x: minX,
                y: minY,
                width: max(maxX - minX, 0),
                height: max(maxY - minY, 0)
            )
            let intersects = projectedRect.intersects(viewRect)

            return SpatialSolveVisibilityCheck(
                accepted: intersects,
                reason: intersects ? "visible" : "projected bounds outside guard rect",
                meshHidden: false,
                projectedOnScreen: intersects,
                projectedBounds: String(
                    format: "x %.1f..%.1f y %.1f..%.1f",
                    Double(minX),
                    Double(maxX),
                    Double(minY),
                    Double(maxY)
                ),
                worldMin: bounds.min,
                worldMax: bounds.max
            )
        }

        private func rigTransformsAreFinite(
            session: SkinnedRigSession
        ) -> Bool {
            guard matrixIsFinite(session.displayRootNode.simdTransform) else {
                return false
            }

            for jointName in session.jointOrder {
                if let bone = session.bonesByCanonicalName[jointName],
                   !matrixIsFinite(bone.simdTransform) {
                    return false
                }
            }

            return true
        }

        private func matrixIsFinite(_ m: simd_float4x4) -> Bool {
            let values = [
                m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
            ]

            return values.allSatisfy { $0.isFinite }
        }

        private func makeSpatialSolveTrace(
            phase: SpatialSolvePhase,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame,
            solveTargetMode: RotoSolveTargetMode,
            spatialRayPinDepthMode: SpatialRayPinDepthMode,
            stats: DepthGuidedRayPinSolveStats,
            session: SkinnedRigSession,
            visibility: SpatialSolveVisibilityCheck,
            lastAcceptedFrame: Int,
            lastRejectedFrame: Int,
            rejectionReason: String
        ) -> SpatialSolveTrace {
            SpatialSolveTrace(
                phase: phase,
                frameIndex: normalizedFrame.frameIndex,
                timeSeconds: normalizedFrame.timeSeconds,
                solveTargetMode: solveTargetMode.rawValue,
                depthMode: spatialRayPinDepthMode.rawValue,
                depthEvidenceJoints: stats.depthEvidenceJoints,
                exactDepthTargets: stats.exactDepthTargets,
                depthCalibrationValid: stats.depthCalibrationValid,
                affineScale: stats.affineScale,
                affineOffset: stats.affineOffset,
                affineAnchorCount: stats.affineAnchorCount,
                affineMedianResidual: stats.affineMedianResidual,
                autoDepthFitZoom: stats.autoDepthZoom,
                autoDepthFitOffset: stats.autoDepthOffset,
                depthFitZoom: stats.depthFitZoom,
                depthFitOffset: stats.depthFitOffset,
                depthFitPivotSceneDepth: stats.depthFitPivotSceneDepth,
                depthFitScore: stats.depthFitScore,
                depthFitBoneResidualMean: stats.depthFitBoneResidualMean,
                depthFitTargetDistanceMean: stats.depthFitTargetDistanceMean,
                displayRootPosition: SIMD3Codable(session.displayRootNode.simdPosition),
                meshWorldBoundsMin: SIMD3Codable(visibility.worldMin),
                meshWorldBoundsMax: SIMD3Codable(visibility.worldMax),
                meshHidden: visibility.meshHidden,
                meshProjectedOnScreen: visibility.projectedOnScreen,
                projectedBounds: visibility.projectedBounds,
                avgRayDistance: stats.avgRayDistance,
                worstJoint: stats.worstJoint,
                worstRayDistance: stats.worstRayDistance,
                lastAcceptedFrame: lastAcceptedFrame,
                lastRejectedFrame: lastRejectedFrame,
                rejectionReason: rejectionReason,
                message: visibility.reason
            )
        }

        private func updateSkinnedRig(
            view: SCNView,
            session: SkinnedRigSession?,
            frame: RotoRayAnimationSolveResult.Frame?,
            frameIndex: Int,
            normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            vision3DFrame: NormalizedVision3DMeshyCapture.Frame?,
            rightNormalizedFrame: NormalizedMeshyPoseCapture.Frame?,
            jointDepthEvidenceFrame: JointDepthEvidenceCapture.Frame?,
            conditionedStereoFrame: ConditionedStereoJointCapture.Frame?,
            fusedStereoTargetFrame: FusedStereoJointTargetCapture.Frame?,
            liveRigPoseSource: LiveRigPoseSource,
            skin3DApplyRevision: Int,
            skin3DViewportRefreshRevision: Int,
            vision3DSkinningAlignmentState: Vision3DSkinningAlignmentState,
            solveTargetMode: RotoSolveTargetMode,
            spatialRayPinDepthMode: SpatialRayPinDepthMode,
            spatialRayPinDepthFitSettings: SpatialRayPinDepthFitSettings,
            autoSpatialDepthFitEnabled: Bool,
            manualSpatialCameraPanX: Double,
            manualSpatialCameraPanY: Double,
            manualSpatialCameraDepthZ: Double,
            spatialCameraOffsetRevision: Int,
            spatialDepthControlRevision: Int,
            spatialSolveTriggerRevision: Int,
            viewportRefreshRevision: Int,
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
            liveRotationPreviewFrameIndexByJoint: [String: Int],
            liveRotationOverridesActive: Bool,
            visible: Bool,
            showSkinnedGeometry: Bool,
            stereoToRigAlignment: StereoToRigAlignment
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
            updateSkinnedGeometryVisibility(
                session: session,
                visible: visible && showSkinnedGeometry
            )

            if applySolvedPoseToReferenceRig,
               liveRigPoseSource == .skin3DVision3D,
               let vision3DFrame {
                let alignment = vision3DSkinningAlignmentState.driverAlignment
                let stats = Vision3DSkinningDriver.skinFrame(
                    vision3DFrame,
                    session: session,
                    alignment: alignment,
                    iterations: 10
                )

                applyViewportRotationOverrides(
                    session: session,
                    overrideLayer: rotationOverrideLayer,
                    liveOverridesActive: liveRotationOverridesActive,
                    liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
                    frameIndex: vision3DFrame.frameIndex,
                    timeSeconds: vision3DFrame.timeSeconds
                )

                session.displayRootNode.isHidden = !visible
                updateSkinnedGeometryVisibility(
                    session: session,
                    visible: visible && showSkinnedGeometry
                )

                if vision3DFrame.frameIndex == 0 ||
                    vision3DFrame.frameIndex % 30 == 0 ||
                    skin3DApplyRevision != lastSkin3DApplyRevision {
                    print("""
                    [RotoSceneVideoViewport] Skin3D Vision3D LIVE CONNECTED APPLY
                      frame: \(vision3DFrame.frameIndex)
                      time: \(String(format: "%.3f", vision3DFrame.timeSeconds))
                      targets: \(stats.targetCount)
                      avgError: \(String(format: "%.5f", stats.avgTargetError))
                      worst: \(stats.worstJoint)
                      worstError: \(String(format: "%.5f", stats.worstError))
                      alignmentValid: \(stats.alignmentValid)
                      alignmentScale: \(String(format: "%.5f", stats.alignmentScale))
                      displayRoot: \(session.displayRootNode.simdPosition)
                      meshHidden: \(session.skinnedMeshNode.isHidden)
                      skin3DApplyRevision: \(skin3DApplyRevision)
                      skin3DViewportRefreshRevision: \(skin3DViewportRefreshRevision)
                    """)

                    print("""
                    [RotoSceneVideoViewport] Skin3D live session identity
                      sessionObject: \(ObjectIdentifier(session as AnyObject))
                      displayRoot: \(session.displayRootNode.name ?? "unnamed")
                      skinnedMesh: \(session.skinnedMeshNode.name ?? "unnamed")
                    """)
                }

                lastSkin3DApplyRevision = skin3DApplyRevision
                view.setNeedsDisplay(view.bounds)
                view.needsDisplay = true
                return
            }

            if applySolvedPoseToReferenceRig,
               solveTargetMode == .spatialDepthGuidedRayPinned,
               let normalizedFrame {
                let spatialSignature = SpatialSolveSignature(
                    frameIndex: normalizedFrame.frameIndex,
                    timeMilliseconds: Int((normalizedFrame.timeSeconds * 1000).rounded()),
                    solveTargetMode: solveTargetMode.rawValue,
                    depthMode: spatialRayPinDepthMode.rawValue,
                    autoDepthFitEnabled: autoSpatialDepthFitEnabled,
                    panXRounded: Int((manualSpatialCameraPanX * 10000).rounded()),
                    panYRounded: Int((manualSpatialCameraPanY * 10000).rounded()),
                    depthZRounded: Int((manualSpatialCameraDepthZ * 10000).rounded()),
                    spatialDepthControlRevision: spatialDepthControlRevision,
                    spatialCameraOffsetRevision: spatialCameraOffsetRevision,
                    spatialSolveTriggerRevision: spatialSolveTriggerRevision,
                    viewportRefreshRevision: viewportRefreshRevision,
                    evidenceFrameIndex: jointDepthEvidenceFrame?.frameIndex
                )
                let previousSpatialSignature = lastSpatialSolveSignature
                let mustRecomputeSpatialSolve = spatialSignature != previousSpatialSignature

                if mustRecomputeSpatialSolve {
                    print("""
                    [RotoSceneVideoViewport] spatial solve recompute
                      frame: \(normalizedFrame.frameIndex)
                      sameFrame: \(previousSpatialSignature?.frameIndex == spatialSignature.frameIndex)
                      autoDepthFitEnabled: \(autoSpatialDepthFitEnabled)
                      panX: \(manualSpatialCameraPanX)
                      panY: \(manualSpatialCameraPanY)
                      depthZ: \(manualSpatialCameraDepthZ)
                      spatialCameraOffsetRevision: \(spatialCameraOffsetRevision)
                      spatialDepthControlRevision: \(spatialDepthControlRevision)
                      spatialSolveTriggerRevision: \(spatialSolveTriggerRevision)
                      viewportRefreshRevision: \(viewportRefreshRevision)
                    """)
                }

                let manualOffsetWorld = cameraSpaceManualOffsetWorld(
                    cameraNode: cameraNode,
                    panX: manualSpatialCameraPanX,
                    panY: manualSpatialCameraPanY,
                    depthZ: manualSpatialCameraDepthZ
                )

                if mustRecomputeSpatialSolve {
                    print("""
                    [RotoSceneVideoViewport] manual spatial camera offset
                      panX: \(manualSpatialCameraPanX)
                      panY: \(manualSpatialCameraPanY)
                      depthZ: \(manualSpatialCameraDepthZ)
                      offsetWorld: \(manualOffsetWorld)
                      sign: depthZ positive = toward camera
                    """)
                }

                session.displayRootNode.isHidden = !visible
                updateSkinnedGeometryVisibility(
                    session: session,
                    visible: visible && showSkinnedGeometry
                )

                let snapshot = makeRigPoseSnapshot(session: session)

                let stats = SkinnedRigRotomationDriver.rotomateFrameWithDepthGuidedRayPins(
                    normalizedFrame: normalizedFrame,
                    jointDepthEvidenceFrame: spatialRayPinDepthMode == .disparityDepthGuided ? jointDepthEvidenceFrame : nil,
                    depthMode: spatialRayPinDepthMode,
                    session: session,
                    cameraOrigin: SIMD3<Float>(0, 0, 0),
                    videoPlaneSize: videoPlaneSize,
                    videoPlaneZ: currentVideoPlaneZ,
                    depthFitSettings: spatialRayPinDepthFitSettings,
                    autoDepthFitEnabled: autoSpatialDepthFitEnabled,
                    manualCameraOffsetWorld: manualOffsetWorld
                )

                if mustRecomputeSpatialSolve {
                    print("""
                    [RotoSceneVideoViewport] camera offset reached driver
                      frame: \(normalizedFrame.frameIndex)
                      autoDepthFitEnabled: \(autoSpatialDepthFitEnabled)
                      panX: \(manualSpatialCameraPanX)
                      panY: \(manualSpatialCameraPanY)
                      depthZ: \(manualSpatialCameraDepthZ)
                      stats.manualCameraOffsetWorld: \(stats.manualCameraOffsetWorld)
                      stats.autoDepthZoom: \(stats.autoDepthZoom)
                      stats.autoDepthOffset: \(stats.autoDepthOffset)
                      stats.finalDepthZoom: \(stats.finalDepthZoom)
                      stats.finalDepthOffset: \(stats.finalDepthOffset)
                      stats.depthFitScore: \(stats.depthFitScore)
                      stats.depthFitResidual: \(stats.depthFitBoneResidualMean)
                    """)
                    lastSpatialSolveSignature = spatialSignature
                    view.setNeedsDisplay(view.bounds)
                    view.needsDisplay = true
                }

                onSpatialDepthFitReadback?(
                    Double(stats.autoDepthZoom),
                    Double(stats.autoDepthOffset),
                    Double(stats.depthFitScore),
                    Double(stats.depthFitBoneResidualMean)
                )

                applyViewportRotationOverrides(
                    session: session,
                    overrideLayer: rotationOverrideLayer,
                    liveOverridesActive: liveRotationOverridesActive,
                    liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
                    frameIndex: normalizedFrame.frameIndex,
                    timeSeconds: normalizedFrame.timeSeconds
                )

                session.displayRootNode.isHidden = !visible
                updateSkinnedGeometryVisibility(
                    session: session,
                    visible: visible && showSkinnedGeometry
                )

                let visibility = checkSolvedRigVisibility(
                    session: session,
                    view: view
                )
                var solvedFrameAccepted = true

                if visible && showSkinnedGeometry && !visibility.accepted {
                    solvedFrameAccepted = false
                    restoreRigPoseSnapshot(snapshot, session: session)
                    session.displayRootNode.isHidden = !visible
                    updateSkinnedGeometryVisibility(
                        session: session,
                        visible: visible && showSkinnedGeometry
                    )

                    let trace = makeSpatialSolveTrace(
                        phase: .frameRejected,
                        normalizedFrame: normalizedFrame,
                        solveTargetMode: solveTargetMode,
                        spatialRayPinDepthMode: spatialRayPinDepthMode,
                        stats: stats,
                        session: session,
                        visibility: visibility,
                        lastAcceptedFrame: -1,
                        lastRejectedFrame: normalizedFrame.frameIndex,
                        rejectionReason: visibility.reason
                    )

                    onSpatialSolveTrace?(trace)

                    print("""
                    [SpatialSolveVisibilityGuard] frame rejected
                      frame: \(normalizedFrame.frameIndex)
                      reason: \(visibility.reason)
                      projected: \(visibility.projectedBounds)
                      root: \(session.displayRootNode.simdPosition)
                      restoredPreviousPose: true
                    """)
                } else {
                    let phase: SpatialSolvePhase = visibility.accepted || !visible || !showSkinnedGeometry
                        ? .frameAccepted
                        : .frameRejected
                    let rejectionReason = phase == .frameAccepted ? "" : visibility.reason
                    let trace = makeSpatialSolveTrace(
                        phase: phase,
                        normalizedFrame: normalizedFrame,
                        solveTargetMode: solveTargetMode,
                        spatialRayPinDepthMode: spatialRayPinDepthMode,
                        stats: stats,
                        session: session,
                        visibility: visibility,
                        lastAcceptedFrame: phase == .frameAccepted ? normalizedFrame.frameIndex : -1,
                        lastRejectedFrame: phase == .frameRejected ? normalizedFrame.frameIndex : -1,
                        rejectionReason: rejectionReason
                    )

                    onSpatialSolveTrace?(trace)

                    if frameIndex % 30 == 0 {
                        print("""
                        [SpatialSolveVisibilityGuard] frame accepted
                          frame: \(normalizedFrame.frameIndex)
                          reason: \(visibility.reason)
                          projected: \(visibility.projectedBounds)
                          root: \(session.displayRootNode.simdPosition)
                          meshHidden: \(visibility.meshHidden)
                        """)
                    }
                }

                if frameIndex == 0 || frameIndex % 30 == 0 {
                    print("""
                    [RotoMotion Visibility Guard] skinned rig visibility
                      showSkinnedRig: \(visible)
                      showSkinnedGeometry: \(showSkinnedGeometry)
                      displayRootHidden: \(session.displayRootNode.isHidden)
                      meshHidden: \(session.skinnedMeshNode.isHidden)
                    """)
                }

                if solvedFrameAccepted,
                   frameIndex % 30 == 0,
                   lastCurvePinnedPlaybackLogFrame != frameIndex {
                    print("[RotoMotion Playback] Applied depth-guided ray-pinned rig frame \(frameIndex)")
                    lastCurvePinnedPlaybackLogFrame = frameIndex
                }
            } else if applySolvedPoseToReferenceRig,
                      solveTargetMode == .monocularRayPinned,
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
                    liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds
                )

                if frameIndex % 30 == 0,
                   lastCurvePinnedPlaybackLogFrame != frameIndex {
                    print("[RotoMotion Playback] Applied curve-pinned rig frame \(frameIndex)")
                    lastCurvePinnedPlaybackLogFrame = frameIndex
                }
            } else if solveTargetMode == .spatialDepthGuidedRayPinned {
                if applySolvedPoseToReferenceRig,
                   frameIndex % 30 == 0,
                   lastCurvePinnedPlaybackLogFrame != frameIndex {
                    print("""
                    [RotoMotion Playback] Stereo target solve skipped
                      frame: \(frameIndex)
                      mode: \(solveTargetMode.rawValue)
                      reason: inactive or unavailable
                      skinned rig remains visible: \(visible)
                    """)
                    lastCurvePinnedPlaybackLogFrame = frameIndex
                }
            } else {
                SkinnedRigRotomationDriver.resetToRest(session: session)
            }
        }

        private func updateSkinnedGeometryVisibility(
            session: SkinnedRigSession,
            visible: Bool
        ) {
            session.skinnedMeshNode.isHidden = !visible

            session.displayRootNode.enumerateChildNodes { node, _ in
                if node.geometry != nil {
                    node.isHidden = !visible
                }
            }
        }

        private func logStereoSolveSkipped(
            frameIndex: Int,
            mode: RotoSolveTargetMode,
            reason: String,
            visible: Bool
        ) {
            guard frameIndex % 30 == 0,
                  lastCurvePinnedPlaybackLogFrame != frameIndex else {
                return
            }

            print("""
            [RotoMotion Playback] Stereo target solve skipped
              frame: \(frameIndex)
              mode: \(mode.rawValue)
              reason: \(reason)
              skinned rig remains visible: \(visible)
            """)
            lastCurvePinnedPlaybackLogFrame = frameIndex
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
            liveRotationPreviewFrameIndexByJoint: [String: Int],
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
                    liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
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

        private func cameraSpaceManualOffsetWorld(
            cameraNode: SCNNode,
            panX: Double,
            panY: Double,
            depthZ: Double
        ) -> SIMD3<Float> {
            let transform = cameraNode.simdWorldTransform
            let cameraRight = normalizeSafe(
                SIMD3<Float>(
                    transform.columns.0.x,
                    transform.columns.0.y,
                    transform.columns.0.z
                ),
                fallback: SIMD3<Float>(1, 0, 0)
            )
            let cameraUp = normalizeSafe(
                SIMD3<Float>(
                    transform.columns.1.x,
                    transform.columns.1.y,
                    transform.columns.1.z
                ),
                fallback: SIMD3<Float>(0, 1, 0)
            )

            // SceneKit cameras look down local -Z. Positive local Z moves toward the camera.
            let cameraToward = normalizeSafe(
                SIMD3<Float>(
                    transform.columns.2.x,
                    transform.columns.2.y,
                    transform.columns.2.z
                ),
                fallback: SIMD3<Float>(0, 0, 1)
            )

            return cameraRight * Float(panX)
                + cameraUp * Float(panY)
                + cameraToward * Float(depthZ)
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
