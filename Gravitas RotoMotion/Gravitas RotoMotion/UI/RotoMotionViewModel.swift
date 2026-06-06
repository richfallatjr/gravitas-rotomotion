import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation
import SceneKit
import SwiftUI
import simd

enum CameraProfile: String, CaseIterable, Identifiable {
    case iPhone17Main1x
    case iPhone17ProMain1x
    case iPhone17UltraWide05x

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iPhone17Main1x:
            return "iPhone 17 Main 1x / 26mm"
        case .iPhone17ProMain1x:
            return "iPhone 17 Pro Main 1x / 24mm"
        case .iPhone17UltraWide05x:
            return "iPhone 17 Ultra Wide 0.5x / 13mm"
        }
    }

    var portraitVerticalFOVDegrees: Double {
        switch self {
        case .iPhone17Main1x:
            return 69.4
        case .iPhone17ProMain1x:
            return 73.7
        case .iPhone17UltraWide05x:
            return 108.4
        }
    }

    var portraitHorizontalFOVDegrees: Double {
        switch self {
        case .iPhone17Main1x:
            return 49.6
        case .iPhone17ProMain1x:
            return 53.1
        case .iPhone17UltraWide05x:
            return 120.0
        }
    }
}

enum RotationGizmoSpace: String, CaseIterable, Identifiable, Codable {
    case local
    case world

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .world:
            return "World"
        }
    }
}

private struct SpatialDisparityBuildProgressSnapshot: Sendable {
    let stage: String
    let completedUnits: Int
    let totalUnits: Int

    var fraction: Double {
        guard totalUnits > 0 else {
            return 0
        }

        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }

    var statusText: String {
        guard totalUnits > 0 else {
            return "\(stage): waiting..."
        }

        return "\(stage): \(completedUnits)/\(totalUnits)"
    }
}

private final class SpatialDisparityBuildProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = SpatialDisparityBuildProgressSnapshot(
        stage: "Preparing disparity build",
        completedUnits: 0,
        totalUnits: 1
    )

    func update(
        stage: String,
        completedUnits: Int,
        totalUnits: Int
    ) {
        lock.lock()
        current = SpatialDisparityBuildProgressSnapshot(
            stage: stage,
            completedUnits: completedUnits,
            totalUnits: max(totalUnits, 1)
        )
        lock.unlock()
    }

    func snapshot() -> SpatialDisparityBuildProgressSnapshot {
        lock.lock()
        let value = current
        lock.unlock()
        return value
    }
}

@MainActor
final class RotoMotionViewModel: ObservableObject {
    enum SessionPoseSource: String {
        case none
        case drawnJointPositions
        case posedArmatureLocalTransforms
    }

    enum RaySolveMode: String, CaseIterable, Identifiable {
        case spineOnly
        case fullBody

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .spineOnly:
                return "Spine Only"
            case .fullBody:
                return "Full Body"
            }
        }

        var solverMode: RotoRayRigSolver.SolveMode {
            switch self {
            case .spineOnly:
                return .spineOnly
            case .fullBody:
                return .fullBody
            }
        }

        var animationSolverMode: RotoRayConstrainedIKSolver.Mode {
            switch self {
            case .spineOnly:
                return .spineOnly
            case .fullBody:
                return .fullBody
            }
        }
    }

    let objectWillChange = ObservableObjectPublisher()
    private let radiansToDegrees = 180.0 / Double.pi
    private let degreesToRadians = Double.pi / 180.0

    @Published var videoURL: URL? {
        didSet { persistURL(videoURL, forKey: AppStorageKeys.videoURL) }
    }
    @Published var outputDirectoryURL: URL? {
        didSet { persistURL(outputDirectoryURL, forKey: AppStorageKeys.outputDirectoryURL) }
    }
    @Published var project: RotoMotionProject?
    @Published var decodedFrames: [RotoVideoFrameCache.CachedFrame] = []
    @Published var currentVideoFrameImage: NSImage?
    @Published var imageRenderToken = 0
    @Published var isFramePlaybackRunning = false
    @Published var framePlaybackFPS = 24.0 {
        didSet { persist(framePlaybackFPS, AppStorageKeys.framePlaybackFPS) }
    }
    @Published var isVideoLooping = true {
        didSet { persist(isVideoLooping, AppStorageKeys.isVideoLooping) }
    }
    @Published var videoPlaybackStatus = "No video loaded."
    @Published var captureMode: RotoMotionCaptureMode = .monocularVideo {
        didSet { persist(captureMode.rawValue, AppStorageKeys.captureMode) }
    }
    @Published var spatialVideoURL: URL? {
        didSet { persistURL(spatialVideoURL, forKey: AppStorageKeys.spatialVideoURL) }
    }
    @Published var leftEyeFrames: [VideoFrame] = []
    @Published var rightEyeFrames: [VideoFrame] = []
    @Published var spatialLeftEyeFrames: [SpatialDecodedEyeFrame] = []
    @Published var spatialRightEyeFrames: [SpatialDecodedEyeFrame] = []
    @Published var spatialDiagnostics: [SpatialEyeFrameDiagnostic] = []
    @Published var spatialDumpDirectoryPath = ""
    @Published var spatialLeftPreviewImage: NSImage?
    @Published var spatialRightPreviewImage: NSImage?
    @Published var spatialDecodeStatus = "No spatial video loaded."
    @Published var rawLeftVisionCapture: RawVisionPoseCapture?
    @Published var rawRightVisionCapture: RawVisionPoseCapture?
    @Published var normalizedLeftCapture: NormalizedMeshyPoseCapture?
    @Published var normalizedRightCapture: NormalizedMeshyPoseCapture?
    @Published var stereoJointCapture: StereoMeshyJointCapture?
    @Published var conditionedStereoJointCapture: ConditionedStereoJointCapture?
    @Published var spatialVideoMetadata: SpatialVideoCameraMetadata?
    @Published var spatialVideoStatus = "No spatial video loaded."
    @Published var spatialStereoAvailable = false
    @Published var spatialDepthStatus = "No stereo depth available."
    @Published var showConditionedStereoSkeleton = true {
        didSet { visibilityToggleChanged(name: "showConditionedStereoSkeleton", value: showConditionedStereoSkeleton) }
    }
    @Published var stereoConditioningStatus = "No conditioned stereo targets."
    @Published var stereoConditioningSettings = StereoTargetConditioningSettings.default
    @Published var spatialDisparityMapCapture: SpatialDisparityMapCapture?
    @Published var spatialDisparityPreviewCapture: SpatialDisparityPreviewCapture?
    @Published var jointDepthEvidenceCapture: JointDepthEvidenceCapture?
    @Published var spatialDisparityStatus = "No disparity map built."
    @Published var spatialDisparityDebugStatus = "No disparity debug proof."
    @Published var spatialDisparityDebugDirectoryPath = ""
    @Published var spatialDisparityDepthPreviewImage: NSImage?
    @Published var spatialDisparityConfidencePreviewImage: NSImage?
    @Published var spatialDisparityRawPreviewImage: NSImage?
    @Published var spatialDisparityDebugFrameIndex = 0
    @Published var showJointDepthValidationOverlay = true {
        didSet { visibilityToggleChanged(name: "showJointDepthValidationOverlay", value: showJointDepthValidationOverlay) }
    }
    @Published var stereoDisparitySettings = StereoDisparitySettings.default
    @Published var isBuildingSpatialDisparity = false
    @Published var spatialDisparityBuildProgress: Double = 0
    @Published var spatialDisparityBuildProgressText = "No disparity build running."
    @Published var spatialDisparityBuildPhase: SpatialDisparityBuildPhase = .idle
    @Published var spatialDisparityProgressFraction: Double = 0
    @Published var spatialDisparityProgressTitle = "No disparity build."
    @Published var spatialDisparityProgressDetail = ""
    @Published var spatialDisparityCurrentFrame = 0
    @Published var spatialDisparityTotalFrames = 0
    @Published var spatialDisparityCurrentRow = 0
    @Published var spatialDisparityTotalRows = 0
    @Published var spatialDisparityElapsedSeconds: Double = 0
    @Published var spatialDisparityEstimatedRemainingSeconds: Double = 0
    @Published var spatialDisparityLastFrameValidPercent: Double = 0
    @Published private(set) var viewportRefreshRevision: Int = 0
    @Published private(set) var rotationKeyRevision: Int = 0
    @Published private(set) var spatialDepthControlRevision: Int = 0
    @Published private(set) var visibilityToggleRevision: Int = 0
    @Published private(set) var disparityProgressRevision: Int = 0
    @Published private(set) var solveInputRevision: Int = 0
    @Published var lastViewportRefreshReason: String = ""
    @Published var spatialSolveReadiness: SpatialSolveReadiness = .notSpatial
    @Published var spatialRayPinDepthMode: SpatialRayPinDepthMode = .leftEyeRayPinningFallback
    @Published var spatialSolveStatus = "No spatial solve ready."
    @Published var spatialSolveTrace = SpatialSolveTrace()
    @Published var spatialSolveProgressFraction: Double = 0
    @Published var spatialSolveProgressTitle = "Spatial solve idle."
    @Published var spatialSolveProgressDetail = ""
    @Published var spatialRayPinDepthFitSettings = SpatialRayPinDepthFitSettings.default
    @Published var autoSpatialDepthFitEnabled = true
    @Published var manualSpatialDepthZoom: Double = 1.0
    @Published var manualSpatialDepthOffset: Double = 0.0
    @Published var lastAutoSpatialDepthZoom: Double = 1.0
    @Published var lastAutoSpatialDepthOffset: Double = 0.0
    @Published var lastSpatialDepthFitScore: Double = 0.0
    @Published var lastSpatialDepthFitResidual: Double = 0.0
    @Published var showDisparityOnImagePlane = true {
        didSet { visibilityToggleChanged(name: "showDisparityOnImagePlane", value: showDisparityOnImagePlane) }
    }
    @Published var disparityPlateOverlayOpacity: Double = 0.65 {
        didSet { visibilityControlChanged(name: "disparityPlateOverlayOpacity") }
    }
    @Published var selectedDisparityPlateOverlay: DisparityPlateOverlayKind = .depth {
        didSet { visibilityControlChanged(name: "selectedDisparityPlateOverlay") }
    }
    @Published var showSpatialTargetBalls = false {
        didSet { visibilityToggleChanged(name: "showSpatialTargetBalls", value: showSpatialTargetBalls) }
    }
    @Published var spatialTargetBallScale: Double = 0.35
    @Published var fusedStereoJointTargetCapture: FusedStereoJointTargetCapture?
    @Published var showFusedStereoTargets = true {
        didSet { visibilityToggleChanged(name: "showFusedStereoTargets", value: showFusedStereoTargets) }
    }
    @Published var fusedStereoTargetStatus = "No fused stereo targets."
    @Published var stereoTargetFusionSettings = StereoTargetFusionSettings.default
    @Published var stereoToRigAlignment: StereoToRigAlignment = .invalid
    @Published var stereoAlignmentStatus = "Stereo-to-rig alignment not calibrated."
    @Published var spatialBaselineMeters: Double = 0.019 {
        didSet {
            persist(spatialBaselineMeters, AppStorageKeys.spatialBaselineMeters)

            if useManualSpatialCameraOverrides {
                updateActiveCameraIntrinsicsForSpatialVideo()
            }
        }
    }
    @Published var spatialHorizontalFOVDegrees: Double = 49.6 {
        didSet {
            persist(spatialHorizontalFOVDegrees, AppStorageKeys.spatialHorizontalFOVDegrees)

            if useManualSpatialCameraOverrides {
                updateActiveCameraIntrinsicsForSpatialVideo()
            }
        }
    }
    @Published var spatialVerticalFOVDegrees: Double = 69.4 {
        didSet { persist(spatialVerticalFOVDegrees, AppStorageKeys.spatialVerticalFOVDegrees) }
    }
    @Published var spatialDisparityAdjustment: Double = 0.0 {
        didSet {
            persist(spatialDisparityAdjustment, AppStorageKeys.spatialDisparityAdjustment)

            if useManualSpatialCameraOverrides {
                updateActiveCameraIntrinsicsForSpatialVideo()
            }
        }
    }
    @Published var useManualSpatialCameraOverrides = false {
        didSet {
            persist(useManualSpatialCameraOverrides, AppStorageKeys.useManualSpatialCameraOverrides)

            if captureMode == .spatialVideo {
                updateActiveCameraIntrinsicsForSpatialVideo()
            }
        }
    }
    @Published var activeCameraProfileSource: ActiveCameraProfileSource = .monocularVerticalProfile
    @Published var activeCameraIntrinsics = RotoCameraIntrinsics(
        source: "monocular vertical default",
        imageWidth: 1080,
        imageHeight: 1920,
        horizontalFOVDegrees: 49.6,
        verticalFOVDegrees: 69.4,
        baselineMeters: nil
    )
    @Published var stereoYConvention: NormalizedImageYConvention = .originBottomLeft {
        didSet {
            persist(stereoYConvention.rawValue, AppStorageKeys.stereoYConvention)

            if oldValue != stereoYConvention,
               normalizedLeftCapture != nil,
               normalizedRightCapture != nil {
                rebuildStereoJointDepthFromCurrentSettings()
            }
        }
    }
    @Published var solveTargetMode: RotoSolveTargetMode = .monocularRayPinned {
        didSet { persist(solveTargetMode.rawValue, AppStorageKeys.solveTargetMode) }
    }
    @Published var showStereo3DSkeleton = true {
        didSet {
            persist(showStereo3DSkeleton, AppStorageKeys.showStereo3DSkeleton)
            visibilityToggleChanged(name: "showStereo3DSkeleton", value: showStereo3DSkeleton)
        }
    }
    @Published var stereoVisionStatus = "No stereo Vision solve yet."

    @Published var currentSessionURL: URL? {
        didSet { persistURL(currentSessionURL, forKey: AppStorageKeys.currentSessionURL) }
    }
    @Published var sessionFileStatus = "No RotoMotion session loaded." {
        didSet { persist(sessionFileStatus, AppStorageKeys.sessionFileStatus) }
    }
    @Published var sessionIsDirty = false {
        didSet { persist(sessionIsDirty, AppStorageKeys.sessionIsDirty) }
    }

    @Published var rawCapture: RawVisionPoseCapture?
    @Published var normalizedCapture: NormalizedMeshyPoseCapture?
    @Published var smoothedCapture: SmoothedMeshyPoseCapture?
    @Published var rigProfile: RigProfile?
    @Published var importedRigScene: ImportedRigScene?
    @Published var fitResult: RigFitResult?

    @Published var currentFrameIndex = 0
    @Published var currentTimeSeconds = 0.0
    @Published var maxFrameIndex = 0

    @Published var sampleFPS = 24.0 {
        didSet { persist(sampleFPS, AppStorageKeys.sampleFPS) }
    }
    @Published var visionSampleFPS = 24.0 {
        didSet { persist(visionSampleFPS, AppStorageKeys.visionSampleFPS) }
    }
    @Published var maxFrames = 0 {
        didSet { persist(maxFrames, AppStorageKeys.maxFrames) }
    }

    @Published var showRawVisionPoints = true {
        didSet {
            persist(showRawVisionPoints, AppStorageKeys.showRawVisionPoints)
            visibilityToggleChanged(name: "showRawVisionPoints", value: showRawVisionPoints)
        }
    }
    @Published var showNormalizedMeshyPoints = true {
        didSet {
            persist(showNormalizedMeshyPoints, AppStorageKeys.showNormalizedMeshyPoints)
            visibilityToggleChanged(name: "showNormalizedMeshyPoints", value: showNormalizedMeshyPoints)
        }
    }
    @Published var showSmoothedMeshyPoints = true {
        didSet {
            persist(showSmoothedMeshyPoints, AppStorageKeys.showSmoothedMeshyPoints)
            visibilityToggleChanged(name: "showSmoothedMeshyPoints", value: showSmoothedMeshyPoints)
        }
    }
    @Published var showSmoothingDeltaVectors = true {
        didSet {
            persist(showSmoothingDeltaVectors, AppStorageKeys.showSmoothingDeltaVectors)
            visibilityToggleChanged(name: "showSmoothingDeltaVectors", value: showSmoothingDeltaVectors)
        }
    }
    @Published var showImportedRigModel = true {
        didSet {
            persist(showImportedRigModel, AppStorageKeys.showImportedRigModel)
            visibilityToggleChanged(name: "showImportedRigModel", value: showImportedRigModel)
        }
    }
    @Published var showImportedRigSkeleton = true {
        didSet {
            persist(showImportedRigSkeleton, AppStorageKeys.showImportedRigSkeleton)
            visibilityToggleChanged(name: "showImportedRigSkeleton", value: showImportedRigSkeleton)
        }
    }
    @Published var showFittedRig = true {
        didSet {
            persist(showFittedRig, AppStorageKeys.showFittedRig)
            visibilityToggleChanged(name: "showFittedRig", value: showFittedRig)
        }
    }
    @Published var rigOverlayScale = 1.0 {
        didSet { persist(rigOverlayScale, AppStorageKeys.rigOverlayScale) }
    }
    @Published var rigOverlayOffsetX = 0.0 {
        didSet { persist(rigOverlayOffsetX, AppStorageKeys.rigOverlayOffsetX) }
    }
    @Published var rigOverlayOffsetY = 0.0 {
        didSet { persist(rigOverlayOffsetY, AppStorageKeys.rigOverlayOffsetY) }
    }

    @Published var groundPlane = GroundPlaneController.default {
        didSet { persistCodable(groundPlane, AppStorageKeys.groundPlane) }
    }

    @Published var smoothingPreviewEnabled = true {
        didSet { persist(smoothingPreviewEnabled, AppStorageKeys.smoothingPreviewEnabled) }
    }
    @Published var smoothingStrength = 0.85 {
        didSet { persist(smoothingStrength, AppStorageKeys.smoothingStrength) }
    }
    @Published var smoothingWindowRadius = 4 {
        didSet { persist(smoothingWindowRadius, AppStorageKeys.smoothingWindowRadius) }
    }
    @Published var smoothingSettings = SmoothedMeshyPoseCapture.SmoothingSettings.default {
        didSet { persistCodable(smoothingSettings, AppStorageKeys.smoothingSettings) }
    }
    @Published var fitSettings = RigFitSettings.default {
        didSet { persistCodable(fitSettings, AppStorageKeys.fitSettings) }
    }
    @Published var projectionSettings = RigProjectionSettings.default {
        didSet { persistCodable(projectionSettings, AppStorageKeys.projectionSettings) }
    }

    @Published var rigOpacity = 0.5 {
        didSet { persist(rigOpacity, AppStorageKeys.rigOpacity) }
    }
    @Published var rigImportStatus = "No USDZ rig loaded."

    @Published var sourceCharacterUSDZURL: URL? {
        didSet { persistURL(sourceCharacterUSDZURL, forKey: AppStorageKeys.sourceCharacterUSDZURL) }
    }
    @Published var exportClipID = "rotomotion_test_01" {
        didSet { persist(exportClipID, AppStorageKeys.exportClipID) }
    }
    @Published var exportDisplayName = "RotoMotion Test 01" {
        didSet { persist(exportDisplayName, AppStorageKeys.exportDisplayName) }
    }
    @Published var exportStatus = "No package exported."
    @Published var animatedUSDZSourceURL: URL? {
        didSet { persistURL(animatedUSDZSourceURL, forKey: AppStorageKeys.animatedUSDZSourceURL) }
    }
    @Published var animatedUSDZClipID = "rotomotion_anim_test_01" {
        didSet { persist(animatedUSDZClipID, AppStorageKeys.animatedUSDZClipID) }
    }
    @Published var animatedUSDZExportStatus = "No animated USDZ exported."
    @Published var openUSDToolStatus: OpenUSDToolStatus?

    @Published var referenceSolveUSDZURL: URL? {
        didSet { persistURL(referenceSolveUSDZURL, forKey: AppStorageKeys.referenceSolveUSDZURL) }
    }
    @Published var targetCharacterUSDZURL: URL? {
        didSet { persistURL(targetCharacterUSDZURL, forKey: AppStorageKeys.targetCharacterUSDZURL) }
    }
    @Published var retargetClipID = "rotomotion_inside_out_01" {
        didSet { persist(retargetClipID, AppStorageKeys.retargetClipID) }
    }
    @Published var includeHipsTranslationInUSDZ = false {
        didSet { persist(includeHipsTranslationInUSDZ, AppStorageKeys.includeHipsTranslationInUSDZ) }
    }
    @Published var skinnedRigSession: SkinnedRigSession?
    @Published var skinnedRigStatus = "No skinned rig loaded."
    @Published var showSkinnedRig = true {
        didSet {
            persist(showSkinnedRig, AppStorageKeys.showSkinnedRig)
            visibilityToggleChanged(name: "showSkinnedRig", value: showSkinnedRig)
        }
    }
    @Published var showSkinnedGeometry = true {
        didSet {
            persist(showSkinnedGeometry, AppStorageKeys.showSkinnedGeometry)
            visibilityToggleChanged(name: "showSkinnedGeometry", value: showSkinnedGeometry)
        }
    }
    @Published var viewportZoom: Double = 2.0 {
        didSet { persist(viewportZoom, AppStorageKeys.viewportZoom) }
    }
    @Published var cameraProfile: CameraProfile = .iPhone17Main1x {
        didSet {
            persist(cameraProfile.rawValue, AppStorageKeys.cameraProfile)

            if activeCameraProfileSource == .monocularVerticalProfile {
                updateActiveCameraIntrinsicsForCurrentMonocularFrame()
            }
        }
    }
    var activeCameraFOVDegrees: Double {
        cameraProfile.portraitVerticalFOVDegrees
    }
    var activeViewportVerticalFOVDegrees: Double {
        activeCameraIntrinsics.verticalFOVDegrees
    }
    var activeViewportCameraProfileName: String {
        activeCameraIntrinsics.source
    }
    var editableJointNames: [String] {
        CanonicalRig.jointNames
    }
    let cameraZ: Float = 0.0
    let defaultReferenceRigZ: Float = -9.0
    let defaultImagePlaneZ: Float = -2000.0
    let referenceRigYawCorrection: Float = .pi
    let referenceRigScaleVisualReduction: Float = 1.0 / 3.0
    @Published var currentVideoPlaneZ: Float = -2000.0 {
        didSet { persist(currentVideoPlaneZ, AppStorageKeys.currentVideoPlaneZ) }
    }
    @Published var referenceRigDefaultZ: Float = -2.0 {
        didSet { persist(referenceRigDefaultZ, AppStorageKeys.referenceRigDefaultZ) }
    }
    @Published var referenceRigCurrentZ: Float = -2.0 {
        didSet { persist(referenceRigCurrentZ, AppStorageKeys.referenceRigCurrentZ) }
    }
    @Published var referenceRigScaleMultiplier: Double = 1.0 {
        didSet { persist(referenceRigScaleMultiplier, AppStorageKeys.referenceRigScaleMultiplier) }
    }
    @Published var referenceRigX: Double = 0.0 {
        didSet { persist(referenceRigX, AppStorageKeys.referenceRigX) }
    }
    @Published var referenceRigY: Double = -0.75 {
        didSet { persist(referenceRigY, AppStorageKeys.referenceRigY) }
    }
    @Published var referenceRigZ: Double = -2.0 {
        didSet { persist(referenceRigZ, AppStorageKeys.referenceRigZ) }
    }
    @Published var referenceRigYawDegrees: Double = 0.0 {
        didSet { persist(referenceRigYawDegrees, AppStorageKeys.referenceRigYawDegrees) }
    }
    @Published var applySolvedPoseToReferenceRig = true {
        didSet { persist(applySolvedPoseToReferenceRig, AppStorageKeys.applySolvedPoseToReferenceRig) }
    }
    @Published var referenceRigVisibleHeightFraction = 0.65 {
        didSet { persist(referenceRigVisibleHeightFraction, AppStorageKeys.referenceRigVisibleHeightFraction) }
    }
    @Published var referenceRigCameraZ = -2.0 {
        didSet { persist(referenceRigCameraZ, AppStorageKeys.referenceRigCameraZ) }
    }
    @Published var referenceRigPlacementStatus = "Reference rig not placed."
    @Published var referenceRigVisibilityStatus = "Reference rig not fitted."
    @Published var referenceRigProfile: USDZSkeletonProfile?
    @Published var jointDebugStatus = "Joint debug not run."
    @Published var jointDebugFrameIndex = 0
    @Published var jointDebugJointName = "RightArm"
    @Published var rigRotationApplyMode: RigRotationApplyMode = .restThenDelta {
        didSet { persist(rigRotationApplyMode.rawValue, AppStorageKeys.rigRotationApplyMode) }
    }
    @Published var bakedRigAnimation: BakedRigAnimation? {
        didSet { persistCodable(bakedRigAnimation, AppStorageKeys.bakedRigAnimation) }
    }
    @Published var bakedRigAnimationStatus = "No baked rig animation." {
        didSet { persist(bakedRigAnimationStatus, AppStorageKeys.bakedRigAnimationStatus) }
    }
    @Published var rotationOverrideLayer = JointRotationOverrideLayer.default
    @Published var selectedRotationJoint = "Head" {
        didSet {
            rotationOverrideLayer.selectedJoint = selectedRotationJoint
            persist(selectedRotationJoint, AppStorageKeys.selectedRotationJoint)
            refreshSelectedJointEulerFields()
        }
    }
    @Published var cleanRotationKeysEnabled = false {
        didSet {
            rotationOverrideLayer.cleanKeysEnabled = cleanRotationKeysEnabled
            if suppressSessionDirtyTracking {
                return
            }

            invalidateBakedAnimationBecauseRotationOverridesChanged()
            applyCurrentFrameToLiveRig()
        }
    }
    @Published var rotationAuthoringStatus = "No held rotation override." {
        didSet { persist(rotationAuthoringStatus, AppStorageKeys.rotationAuthoringStatus) }
    }
    @Published var showRotationGizmo = true {
        didSet { visibilityToggleChanged(name: "showRotationGizmo", value: showRotationGizmo) }
    }
    @Published var rotationGizmoSpace: RotationGizmoSpace = .local
    @Published var rotationGizmoStatus = "No rotation gizmo interaction."
    @Published var heldRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:]
    @Published var liveRotationOverrideEulerXYZByJoint: [String: SIMD3<Float>] = [:]
    @Published var liveRotationPreviewFrameIndexByJoint: [String: Int] = [:]
    @Published private(set) var rotationOverrideRevision: Int = 0
    @Published var isRotationGizmoDragging = false
    @Published var selectedJointEulerDegreesX: Double = 0.0
    @Published var selectedJointEulerDegreesY: Double = 0.0
    @Published var selectedJointEulerDegreesZ: Double = 0.0
    @Published var isUpdatingEulerFieldsFromSelection = false
    @Published var sessionSkeletonPath: String?
    @Published var sessionJointPaths: [String] = []
    @Published var sessionJointLeafNames: [String] = []
    @Published var sessionSkeletonStatus = "No session skeleton captured."
    @Published var sessionPoseSource: SessionPoseSource = .none
    @Published var sessionPoseStatus = "No session pose source detected."
    @Published var usdzRetargetStatus = "No animated target USDZ exported."
    @Published var lastAnimatedUSDZExportURL: URL? {
        didSet { persistURL(lastAnimatedUSDZExportURL, forKey: AppStorageKeys.lastAnimatedUSDZExportURL) }
    }
    @Published var lastAnimatedUSDZExportFolderURL: URL? {
        didSet { persistURL(lastAnimatedUSDZExportFolderURL, forKey: AppStorageKeys.lastAnimatedUSDZExportFolderURL) }
    }

    @Published var showVisionRays = true {
        didSet {
            persist(showVisionRays, AppStorageKeys.showVisionRays)
            visibilityToggleChanged(name: "showVisionRays", value: showVisionRays)
        }
    }
    @Published var showRaySolvedRig = true {
        didSet {
            persist(showRaySolvedRig, AppStorageKeys.showRaySolvedRig)
            visibilityToggleChanged(name: "showRaySolvedRig", value: showRaySolvedRig)
        }
    }
    @Published var showDebugSolvedSkeleton = false {
        didSet {
            persist(showDebugSolvedSkeleton, AppStorageKeys.showDebugSolvedSkeleton)
            visibilityToggleChanged(name: "showDebugSolvedSkeleton", value: showDebugSolvedSkeleton)
        }
    }
    @Published var rayLength = Double(RotoRayRigSolver.defaultRayLength) {
        didSet { persist(rayLength, AppStorageKeys.rayLength) }
    }
    @Published var rayTargetHeightMeters = 1.74 {
        didSet { persist(rayTargetHeightMeters, AppStorageKeys.rayTargetHeightMeters) }
    }
    @Published var raySceneUnitsPerMeter = 5.0 {
        didSet { persist(raySceneUnitsPerMeter, AppStorageKeys.raySceneUnitsPerMeter) }
    }
    var stereoMetersToRigSceneUnits: Float {
        let unitScaleToMeters = Float(referenceRigProfile?.unitScaleToMeters ?? 1.0)

        guard unitScaleToMeters > 0 else {
            return 1.0
        }

        return 1.0 / unitScaleToMeters
    }
    @Published var useCalibratedRigDepth = false {
        didSet { persist(useCalibratedRigDepth, AppStorageKeys.useCalibratedRigDepth) }
    }
    @Published var calibratedRigDepthZ = 0.0 {
        didSet { persist(calibratedRigDepthZ, AppStorageKeys.calibratedRigDepthZ) }
    }
    @Published var projectionScaleError = 0.0 {
        didSet { persist(projectionScaleError, AppStorageKeys.projectionScaleError) }
    }
    @Published var depthCalibrationStatus = "Depth calibration not run."
    @Published var forceCameraFacingYaw = true {
        didSet { persist(forceCameraFacingYaw, AppStorageKeys.forceCameraFacingYaw) }
    }
    @Published var raySolveMode: RaySolveMode = .fullBody {
        didSet { persist(raySolveMode.rawValue, AppStorageKeys.raySolveMode) }
    }
    @Published var currentVideoPlaneSize: CGSize?
    @Published var currentRaySolveResult: RotoRaySolveResult?
    @Published var raySolveStatus = "Ray solve not run."
    @Published var rayAnimationSolveResult: RotoRayAnimationSolveResult?
    @Published var sessionArmatureSnapshot: SessionArmatureSnapshot?
    @Published var sessionArmaturePoseBuffer: SessionArmaturePoseBuffer?
    @Published var rayAnimationSolveStatus = "Ray animation solve not run."
    @Published var raySolvedUSDZClipID = "rotomotion_ray_solve_01" {
        didSet { persist(raySolvedUSDZClipID, AppStorageKeys.raySolvedUSDZClipID) }
    }
    @Published var raySolvedUSDZExportStatus = "No ray solve USDZ exported."

    @Published var status = "Open a video to begin."
    @Published var logLines: [String] = ["Ready."]
    @Published var isWorking = false
    @Published var diagnostics = RotoMotionDiagnostics()

    @Published var lastLoadedVideoURL: URL?
    @Published var lastVisionError: String?
    @Published var lastNormalizeError: String?
    @Published var lastSmoothingError: String?
    @Published var lastRigError: String?

    private let exporter = RotoMotionExporter()
    private var videoSecurityScopedURL: URL?
    private var videoSecurityScopedAccessActive = false
    private var playbackTask: Task<Void, Never>?
    private var playbackStartHostTime: Date?
    private var playbackStartVideoTime = 0.0
    private var audioPlayer: AVPlayer?
    private var audioEndObserver: NSObjectProtocol?
    private var spatialDisparityProgressTask: Task<Void, Never>?
    private var disparityUIHeartbeatTask: Task<Void, Never>?
    private var lastDisparityProgressLogTime: Date = .distantPast
    private var suppressSessionDirtyTracking = false

    init() {
        loadPersistedAppStorageFields()
        restorePersistedReferenceRigIfAvailable()
    }

    deinit {
        playbackTask?.cancel()

        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
        }

        if videoSecurityScopedAccessActive,
           let videoSecurityScopedURL {
            videoSecurityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    private enum AppStorageKeys {
        static let prefix = "com.gravitas.rotomotion."

        static let videoURL = prefix + "videoURL"
        static let outputDirectoryURL = prefix + "outputDirectoryURL"
        static let currentSessionURL = prefix + "currentSessionURL"
        static let sessionFileStatus = prefix + "sessionFileStatus"
        static let sessionIsDirty = prefix + "sessionIsDirty"
        static let framePlaybackFPS = prefix + "framePlaybackFPS"
        static let isVideoLooping = prefix + "isVideoLooping"
        static let captureMode = prefix + "captureMode"
        static let spatialVideoURL = prefix + "spatialVideoURL"
        static let spatialBaselineMeters = prefix + "spatialBaselineMeters"
        static let spatialHorizontalFOVDegrees = prefix + "spatialHorizontalFOVDegrees"
        static let spatialVerticalFOVDegrees = prefix + "spatialVerticalFOVDegrees"
        static let spatialDisparityAdjustment = prefix + "spatialDisparityAdjustment"
        static let useManualSpatialCameraOverrides = prefix + "useManualSpatialCameraOverrides"
        static let stereoYConvention = prefix + "stereoYConvention"
        static let solveTargetMode = prefix + "solveTargetMode"
        static let showStereo3DSkeleton = prefix + "showStereo3DSkeleton"
        static let sampleFPS = prefix + "sampleFPS"
        static let visionSampleFPS = prefix + "visionSampleFPS"
        static let maxFrames = prefix + "maxFrames"
        static let showRawVisionPoints = prefix + "showRawVisionPoints"
        static let showNormalizedMeshyPoints = prefix + "showNormalizedMeshyPoints"
        static let showSmoothedMeshyPoints = prefix + "showSmoothedMeshyPoints"
        static let showSmoothingDeltaVectors = prefix + "showSmoothingDeltaVectors"
        static let showImportedRigModel = prefix + "showImportedRigModel"
        static let showImportedRigSkeleton = prefix + "showImportedRigSkeleton"
        static let showFittedRig = prefix + "showFittedRig"
        static let rigOverlayScale = prefix + "rigOverlayScale"
        static let rigOverlayOffsetX = prefix + "rigOverlayOffsetX"
        static let rigOverlayOffsetY = prefix + "rigOverlayOffsetY"
        static let groundPlane = prefix + "groundPlane"
        static let smoothingPreviewEnabled = prefix + "smoothingPreviewEnabled"
        static let smoothingStrength = prefix + "smoothingStrength"
        static let smoothingWindowRadius = prefix + "smoothingWindowRadius"
        static let smoothingSettings = prefix + "smoothingSettings"
        static let fitSettings = prefix + "fitSettings"
        static let projectionSettings = prefix + "projectionSettings"
        static let rigOpacity = prefix + "rigOpacity"
        static let sourceCharacterUSDZURL = prefix + "sourceCharacterUSDZURL"
        static let exportClipID = prefix + "exportClipID"
        static let exportDisplayName = prefix + "exportDisplayName"
        static let animatedUSDZSourceURL = prefix + "animatedUSDZSourceURL"
        static let animatedUSDZClipID = prefix + "animatedUSDZClipID"
        static let referenceSolveUSDZURL = prefix + "referenceSolveUSDZURL"
        static let targetCharacterUSDZURL = prefix + "targetCharacterUSDZURL"
        static let retargetClipID = prefix + "retargetClipID"
        static let includeHipsTranslationInUSDZ = prefix + "includeHipsTranslationInUSDZ"
        static let showSkinnedRig = prefix + "showSkinnedRig"
        static let showSkinnedGeometry = prefix + "showSkinnedGeometry"
        static let viewportZoom = prefix + "viewportZoom"
        static let cameraProfile = prefix + "cameraProfile"
        static let currentVideoPlaneZ = prefix + "currentVideoPlaneZ"
        static let referenceRigDefaultZ = prefix + "referenceRigDefaultZ"
        static let referenceRigCurrentZ = prefix + "referenceRigCurrentZ"
        static let referenceRigScaleMultiplier = prefix + "referenceRigScaleMultiplier"
        static let referenceRigX = prefix + "referenceRigX"
        static let referenceRigY = prefix + "referenceRigY"
        static let referenceRigZ = prefix + "referenceRigZ"
        static let referenceRigYawDegrees = prefix + "referenceRigYawDegrees"
        static let applySolvedPoseToReferenceRig = prefix + "applySolvedPoseToReferenceRig"
        static let referenceRigVisibleHeightFraction = prefix + "referenceRigVisibleHeightFraction"
        static let referenceRigCameraZ = prefix + "referenceRigCameraZ"
        static let rigRotationApplyMode = prefix + "rigRotationApplyMode"
        static let bakedRigAnimation = prefix + "bakedRigAnimation"
        static let bakedRigAnimationStatus = prefix + "bakedRigAnimationStatus"
        static let legacyRotationOverrideLayer = prefix + "rotationOverrideLayer"
        static let legacyHeldRotationOverrideEulerXYZByJoint = prefix + "heldRotationOverrideEulerXYZByJoint"
        static let selectedRotationJoint = prefix + "selectedRotationJoint"
        static let cleanRotationKeysEnabled = prefix + "cleanRotationKeysEnabled"
        static let rotationAuthoringStatus = prefix + "rotationAuthoringStatus"
        static let lastAnimatedUSDZExportURL = prefix + "lastAnimatedUSDZExportURL"
        static let lastAnimatedUSDZExportFolderURL = prefix + "lastAnimatedUSDZExportFolderURL"
        static let showVisionRays = prefix + "showVisionRays"
        static let showRaySolvedRig = prefix + "showRaySolvedRig"
        static let showDebugSolvedSkeleton = prefix + "showDebugSolvedSkeleton"
        static let rayLength = prefix + "rayLength"
        static let rayTargetHeightMeters = prefix + "rayTargetHeightMeters"
        static let raySceneUnitsPerMeter = prefix + "raySceneUnitsPerMeter"
        static let useCalibratedRigDepth = prefix + "useCalibratedRigDepth"
        static let calibratedRigDepthZ = prefix + "calibratedRigDepthZ"
        static let projectionScaleError = prefix + "projectionScaleError"
        static let forceCameraFacingYaw = prefix + "forceCameraFacingYaw"
        static let raySolveMode = prefix + "raySolveMode"
        static let raySolvedUSDZClipID = prefix + "raySolvedUSDZClipID"
    }

    private static let appStorage = UserDefaults.standard

    private func persist(_ value: Bool, _ key: String) {
        Self.appStorage.set(value, forKey: key)
    }

    private func persist(_ value: Int, _ key: String) {
        Self.appStorage.set(value, forKey: key)
    }

    private func persist(_ value: Double, _ key: String) {
        Self.appStorage.set(value, forKey: key)
    }

    private func persist(_ value: Float, _ key: String) {
        Self.appStorage.set(Double(value), forKey: key)
    }

    private func persist(_ value: String, _ key: String) {
        Self.appStorage.set(value, forKey: key)
    }

    private func persistURL(_ url: URL?, forKey key: String) {
        guard let url else {
            Self.appStorage.removeObject(forKey: key)
            return
        }

        Self.appStorage.set(url.standardizedFileURL.path, forKey: key)
    }

    private func persistCodable<T: Encodable>(_ value: T, _ key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            Self.appStorage.set(data, forKey: key)
        } catch {
            diagnostics.log("App storage encode failed for \(key): \(error.localizedDescription)")
        }
    }

    private func persistCodable<T: Encodable>(_ value: T?, _ key: String) {
        guard let value else {
            Self.appStorage.removeObject(forKey: key)
            return
        }

        persistCodable(value, key)
    }

    private func storedBool(_ key: String) -> Bool? {
        guard Self.appStorage.object(forKey: key) != nil else { return nil }
        return Self.appStorage.bool(forKey: key)
    }

    private func storedInt(_ key: String) -> Int? {
        guard Self.appStorage.object(forKey: key) != nil else { return nil }
        return Self.appStorage.integer(forKey: key)
    }

    private func storedDouble(_ key: String) -> Double? {
        guard Self.appStorage.object(forKey: key) != nil else { return nil }
        return Self.appStorage.double(forKey: key)
    }

    private func storedFloat(_ key: String) -> Float? {
        guard let value = storedDouble(key) else { return nil }
        return Float(value)
    }

    private func storedString(_ key: String) -> String? {
        guard let value = Self.appStorage.string(forKey: key), !value.isEmpty else {
            return nil
        }

        return value
    }

    private func storedURL(_ key: String) -> URL? {
        guard let path = storedString(key) else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    private func storedCodable<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = Self.appStorage.data(forKey: key) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            diagnostics.log("App storage decode failed for \(key): \(error.localizedDescription)")
            return nil
        }
    }

    private func purgeLegacyRotationOverrideAppStorage() {
        Self.appStorage.removeObject(forKey: AppStorageKeys.legacyRotationOverrideLayer)
        Self.appStorage.removeObject(forKey: AppStorageKeys.legacyHeldRotationOverrideEulerXYZByJoint)
    }

    private func codableHeldRotationOverrides() -> [String: SIMD3Codable] {
        heldRotationOverrideEulerXYZByJoint.mapValues {
            SIMD3Codable(
                x: Double($0.x),
                y: Double($0.y),
                z: Double($0.z)
            )
        }
    }

    private func simdHeldRotationOverrides(
        _ values: [String: SIMD3Codable]
    ) -> [String: SIMD3<Float>] {
        values.mapValues { $0.simdFloat }
    }

    func resetRotationAuthoringForNewSession() {
        let selectedJoint = selectedRotationJoint

        rotationOverrideLayer = JointRotationOverrideLayer.default
        selectedRotationJoint = selectedJoint
        cleanRotationKeysEnabled = false
        rotationOverrideLayer.selectedJoint = selectedJoint
        rotationOverrideLayer.cleanKeysEnabled = false
        heldRotationOverrideEulerXYZByJoint = [:]
        liveRotationOverrideEulerXYZByJoint = [:]
        liveRotationPreviewFrameIndexByJoint = [:]
        rotationOverrideRevision += 1
        isRotationGizmoDragging = false
        rotationAuthoringStatus = "No held rotation override."
        rotationGizmoStatus = "No rotation gizmo interaction."
        refreshSelectedJointEulerFields()
    }

    private func loadPersistedAppStorageFields() {
        suppressSessionDirtyTracking = true
        defer {
            suppressSessionDirtyTracking = false
        }

        purgeLegacyRotationOverrideAppStorage()

        videoURL = storedURL(AppStorageKeys.videoURL)
        spatialVideoURL = storedURL(AppStorageKeys.spatialVideoURL)
        outputDirectoryURL = storedURL(AppStorageKeys.outputDirectoryURL)
        currentSessionURL = storedURL(AppStorageKeys.currentSessionURL)
        sourceCharacterUSDZURL = storedURL(AppStorageKeys.sourceCharacterUSDZURL)
        animatedUSDZSourceURL = storedURL(AppStorageKeys.animatedUSDZSourceURL)
        referenceSolveUSDZURL = storedURL(AppStorageKeys.referenceSolveUSDZURL)
        targetCharacterUSDZURL = storedURL(AppStorageKeys.targetCharacterUSDZURL)
        lastAnimatedUSDZExportURL = storedURL(AppStorageKeys.lastAnimatedUSDZExportURL)
        lastAnimatedUSDZExportFolderURL = storedURL(AppStorageKeys.lastAnimatedUSDZExportFolderURL)

        if let value = storedDouble(AppStorageKeys.framePlaybackFPS) { framePlaybackFPS = value }
        if let value = storedBool(AppStorageKeys.isVideoLooping) { isVideoLooping = value }
        if let rawValue = storedString(AppStorageKeys.captureMode),
           let value = RotoMotionCaptureMode(rawValue: rawValue) {
            captureMode = value
        }
        if let value = storedDouble(AppStorageKeys.spatialBaselineMeters) { spatialBaselineMeters = value }
        if let value = storedDouble(AppStorageKeys.spatialHorizontalFOVDegrees) { spatialHorizontalFOVDegrees = value }
        if let value = storedDouble(AppStorageKeys.spatialVerticalFOVDegrees) { spatialVerticalFOVDegrees = value }
        if let value = storedDouble(AppStorageKeys.spatialDisparityAdjustment) { spatialDisparityAdjustment = value }
        if let value = storedBool(AppStorageKeys.useManualSpatialCameraOverrides) { useManualSpatialCameraOverrides = value }
        if let rawValue = storedString(AppStorageKeys.stereoYConvention),
           let value = NormalizedImageYConvention(rawValue: rawValue) {
            stereoYConvention = value
        }
        if let rawValue = storedString(AppStorageKeys.solveTargetMode),
           let value = RotoSolveTargetMode(rawValue: rawValue) {
            solveTargetMode = value
        }
        if let value = storedBool(AppStorageKeys.showStereo3DSkeleton) { showStereo3DSkeleton = value }
        if let value = storedString(AppStorageKeys.sessionFileStatus) { sessionFileStatus = value }
        if let value = storedBool(AppStorageKeys.sessionIsDirty) { sessionIsDirty = value }
        if let value = storedDouble(AppStorageKeys.sampleFPS) { sampleFPS = value }
        if let value = storedDouble(AppStorageKeys.visionSampleFPS) { visionSampleFPS = value }
        if let value = storedInt(AppStorageKeys.maxFrames) { maxFrames = value }

        if let value = storedBool(AppStorageKeys.showRawVisionPoints) { showRawVisionPoints = value }
        if let value = storedBool(AppStorageKeys.showNormalizedMeshyPoints) { showNormalizedMeshyPoints = value }
        if let value = storedBool(AppStorageKeys.showSmoothedMeshyPoints) { showSmoothedMeshyPoints = value }
        if let value = storedBool(AppStorageKeys.showSmoothingDeltaVectors) { showSmoothingDeltaVectors = value }
        if let value = storedBool(AppStorageKeys.showImportedRigModel) { showImportedRigModel = value }
        if let value = storedBool(AppStorageKeys.showImportedRigSkeleton) { showImportedRigSkeleton = value }
        if let value = storedBool(AppStorageKeys.showFittedRig) { showFittedRig = value }
        if let value = storedDouble(AppStorageKeys.rigOverlayScale) { rigOverlayScale = value }
        if let value = storedDouble(AppStorageKeys.rigOverlayOffsetX) { rigOverlayOffsetX = value }
        if let value = storedDouble(AppStorageKeys.rigOverlayOffsetY) { rigOverlayOffsetY = value }
        if let value = storedCodable(GroundPlaneController.self, AppStorageKeys.groundPlane) { groundPlane = value }

        if let value = storedBool(AppStorageKeys.smoothingPreviewEnabled) { smoothingPreviewEnabled = value }
        if let value = storedDouble(AppStorageKeys.smoothingStrength) { smoothingStrength = value }
        if let value = storedInt(AppStorageKeys.smoothingWindowRadius) { smoothingWindowRadius = value }
        if let value = storedCodable(SmoothedMeshyPoseCapture.SmoothingSettings.self, AppStorageKeys.smoothingSettings) { smoothingSettings = value }
        if let value = storedCodable(RigFitSettings.self, AppStorageKeys.fitSettings) { fitSettings = value }
        if let value = storedCodable(RigProjectionSettings.self, AppStorageKeys.projectionSettings) { projectionSettings = value }
        if let value = storedDouble(AppStorageKeys.rigOpacity) { rigOpacity = value }

        if let value = storedString(AppStorageKeys.exportClipID) { exportClipID = value }
        if let value = storedString(AppStorageKeys.exportDisplayName) { exportDisplayName = value }
        if let value = storedString(AppStorageKeys.animatedUSDZClipID) { animatedUSDZClipID = value }
        if let value = storedString(AppStorageKeys.retargetClipID) { retargetClipID = value }
        if let value = storedBool(AppStorageKeys.includeHipsTranslationInUSDZ) { includeHipsTranslationInUSDZ = value }

        if let value = storedBool(AppStorageKeys.showSkinnedRig) { showSkinnedRig = value }
        if let value = storedBool(AppStorageKeys.showSkinnedGeometry) { showSkinnedGeometry = value }
        if let value = storedDouble(AppStorageKeys.viewportZoom) { viewportZoom = value }
        if let rawValue = storedString(AppStorageKeys.cameraProfile),
           let value = CameraProfile(rawValue: rawValue) {
            cameraProfile = value
        }
        if let value = storedFloat(AppStorageKeys.currentVideoPlaneZ) { currentVideoPlaneZ = value }
        if let value = storedFloat(AppStorageKeys.referenceRigDefaultZ) { referenceRigDefaultZ = value }
        if let value = storedFloat(AppStorageKeys.referenceRigCurrentZ) { referenceRigCurrentZ = value }
        if let value = storedDouble(AppStorageKeys.referenceRigVisibleHeightFraction) { referenceRigVisibleHeightFraction = value }
        if let value = storedDouble(AppStorageKeys.referenceRigCameraZ) { referenceRigCameraZ = value }
        if let rawValue = storedString(AppStorageKeys.rigRotationApplyMode),
           let value = RigRotationApplyMode(rawValue: rawValue) {
            rigRotationApplyMode = value
        }
        if let value = storedString(AppStorageKeys.selectedRotationJoint) { selectedRotationJoint = value }
        if let value = storedString(AppStorageKeys.rotationAuthoringStatus) { rotationAuthoringStatus = value }
        if let value = storedCodable(BakedRigAnimation.self, AppStorageKeys.bakedRigAnimation) { bakedRigAnimation = value }
        if let value = storedString(AppStorageKeys.bakedRigAnimationStatus) { bakedRigAnimationStatus = value }

        if let value = storedBool(AppStorageKeys.showVisionRays) { showVisionRays = value }
        if let value = storedBool(AppStorageKeys.showRaySolvedRig) { showRaySolvedRig = value }
        if let value = storedBool(AppStorageKeys.showDebugSolvedSkeleton) { showDebugSolvedSkeleton = value }
        if let value = storedDouble(AppStorageKeys.rayLength) { rayLength = value }
        if let value = storedDouble(AppStorageKeys.rayTargetHeightMeters) { rayTargetHeightMeters = value }
        if let value = storedDouble(AppStorageKeys.raySceneUnitsPerMeter) { raySceneUnitsPerMeter = value }
        if let value = storedBool(AppStorageKeys.useCalibratedRigDepth) { useCalibratedRigDepth = value }
        if let value = storedDouble(AppStorageKeys.calibratedRigDepthZ) { calibratedRigDepthZ = value }
        if let value = storedDouble(AppStorageKeys.projectionScaleError) { projectionScaleError = value }
        if let value = storedBool(AppStorageKeys.forceCameraFacingYaw) { forceCameraFacingYaw = value }
        if let rawValue = storedString(AppStorageKeys.raySolveMode),
           let value = RaySolveMode(rawValue: rawValue) {
            raySolveMode = value
        }
        if let value = storedString(AppStorageKeys.raySolvedUSDZClipID) { raySolvedUSDZClipID = value }

        if let videoURL {
            lastLoadedVideoURL = videoURL
        }

        diagnostics.log("Restored app storage fields.")
    }

    private func restorePersistedReferenceRigIfAvailable() {
        guard let url = referenceSolveUSDZURL else {
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            diagnostics.log("Stored reference USDZ path no longer exists: \(url.path)")
            return
        }

        diagnostics.log("Restoring stored reference solve USDZ: \(url.path)")
        let restoredBakedRigAnimation = bakedRigAnimation
        inspectReferenceUSDZ()
        loadSkinnedRigUSDZFromReference(url)

        if let restoredBakedRigAnimation {
            bakedRigAnimation = restoredBakedRigAnimation
            sessionArmaturePoseBuffer = restoredBakedRigAnimation.asSessionArmaturePoseBuffer()
            bakedRigAnimationStatus = "Restored baked rig animation: \(restoredBakedRigAnimation.frames.count) frames."
        }
    }

    func makeSessionDocument() -> RotoMotionSessionDocument {
        RotoMotionSessionDocument(
            schema: RotoMotionSessionDocument.currentSchema,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            savedAt: Date(),
            clipID: retargetClipID,
            videoURLPath: videoURL?.path,
            referenceUSDZPath: referenceSolveUSDZURL?.path,
            targetUSDZPath: targetCharacterUSDZURL?.path,
            currentFrameIndex: currentFrameIndex,
            currentVideoTimeSeconds: currentVideoTimeSeconds,
            cameraProfileRawValue: cameraProfile.rawValue,
            cameraFOVDegrees: activeCameraFOVDegrees,
            imagePlaneDistance: Double(currentVideoPlaneZ),
            showRawVision: showRawVisionPoints,
            showNormalizedMeshy: showNormalizedMeshyPoints,
            showSkinnedRig: showSkinnedRig,
            showDebugSolvedSkeleton: showDebugSolvedSkeleton,
            referenceRigX: referenceRigX,
            referenceRigY: referenceRigY,
            referenceRigZ: referenceRigZ,
            referenceRigRotationXDegrees: -90.0,
            referenceRigRotationYDegrees: 360.0,
            referenceRigScale: referenceRigScaleMultiplier,
            rawCapture: rawCapture,
            normalizedCapture: normalizedCapture,
            rayAnimationSolveResult: rayAnimationSolveResult,
            bakedRigAnimation: bakedRigAnimation,
            rotationOverrideLayer: rotationOverrideLayer,
            heldRotationOverrideEulerXYZByJoint: codableHeldRotationOverrides(),
            selectedRotationJoint: selectedRotationJoint,
            cleanRotationKeysEnabled: cleanRotationKeysEnabled
        )
    }

    func saveRotoMotionSession() {
        let defaultName = retargetClipID.isEmpty ? "RotoMotionSession" : retargetClipID

        guard let url = currentSessionURL ?? FilePanelHelpers.saveRotoMotionSessionURL(defaultName: defaultName) else {
            sessionFileStatus = "Save canceled."
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
            return
        }

        do {
            let document = makeSessionDocument()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)

            currentSessionURL = url
            sessionIsDirty = false
            sessionFileStatus = "Saved RotoMotion session: \(url.path)"
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
        } catch {
            sessionFileStatus = "Save failed: \(error.localizedDescription)"
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
        }
    }

    func saveRotoMotionSessionAs() {
        let defaultName = retargetClipID.isEmpty ? "RotoMotionSession" : retargetClipID

        guard let url = FilePanelHelpers.saveRotoMotionSessionURL(defaultName: defaultName) else {
            sessionFileStatus = "Save As canceled."
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
            return
        }

        currentSessionURL = url
        saveRotoMotionSession()
    }

    func openRotoMotionSession() {
        guard let url = FilePanelHelpers.openRotoMotionSessionURL() else {
            sessionFileStatus = "Open session canceled."
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
            return
        }

        loadRotoMotionSession(from: url)
    }

    func loadRotoMotionSession(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let document = try decoder.decode(RotoMotionSessionDocument.self, from: data)

            guard document.schema == RotoMotionSessionDocument.currentSchema else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 15001,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unsupported RotoMotion session schema: \(document.schema)"
                    ]
                )
            }

            applySessionDocument(document)

            currentSessionURL = url
            sessionIsDirty = false
            sessionFileStatus = "Loaded RotoMotion session: \(url.path)"
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
        } catch {
            sessionFileStatus = "Load failed: \(error.localizedDescription)"
            status = sessionFileStatus
            diagnostics.log(sessionFileStatus)
        }
    }

    func applySessionDocument(_ document: RotoMotionSessionDocument) {
        suppressSessionDirtyTracking = true
        defer {
            suppressSessionDirtyTracking = false
        }

        retargetClipID = document.clipID

        if let path = document.videoURLPath {
            let url = URL(fileURLWithPath: path)
            videoURL = url
            lastLoadedVideoURL = url
            outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        } else {
            videoURL = nil
            lastLoadedVideoURL = nil
        }

        targetCharacterUSDZURL = document.targetUSDZPath.map {
            URL(fileURLWithPath: $0)
        }

        currentFrameIndex = document.currentFrameIndex
        currentTimeSeconds = document.currentVideoTimeSeconds

        if let restoredProfile = CameraProfile(rawValue: document.cameraProfileRawValue) {
            cameraProfile = restoredProfile
        }

        currentVideoPlaneZ = Float(document.imagePlaneDistance)

        showRawVisionPoints = document.showRawVision
        showNormalizedMeshyPoints = document.showNormalizedMeshy
        showSkinnedRig = document.showSkinnedRig
        showDebugSolvedSkeleton = document.showDebugSolvedSkeleton

        referenceRigX = document.referenceRigX
        referenceRigY = document.referenceRigY
        referenceRigZ = document.referenceRigZ
        referenceRigScaleMultiplier = document.referenceRigScale
        referenceRigYawDegrees = document.referenceRigRotationYDegrees

        rawCapture = document.rawCapture
        normalizedCapture = document.normalizedCapture
        rayAnimationSolveResult = document.rayAnimationSolveResult

        if let path = document.referenceUSDZPath {
            let url = URL(fileURLWithPath: path)
            referenceSolveUSDZURL = url

            if FileManager.default.fileExists(atPath: path) {
                inspectReferenceUSDZ()
                loadSkinnedRigUSDZFromReference(url)
            } else {
                skinnedRigSession = nil
                invalidateStereoToRigAlignment("session reference USDZ path missing")
                skinnedRigStatus = "Reference USDZ path from session no longer exists: \(path)"
                diagnostics.log(skinnedRigStatus)
            }
        } else {
            referenceSolveUSDZURL = nil
            skinnedRigSession = nil
            invalidateStereoToRigAlignment("session has no reference USDZ")
            skinnedRigStatus = "No skinned rig loaded."
        }

        bakedRigAnimation = document.bakedRigAnimation
        sessionArmaturePoseBuffer = document.bakedRigAnimation?.asSessionArmaturePoseBuffer()
        if let bakedRigAnimation {
            bakedRigAnimationStatus = "Loaded baked rig animation: \(bakedRigAnimation.frames.count) frames."
            sessionPoseSource = .posedArmatureLocalTransforms
            sessionPoseStatus = "Loaded baked rig animation from RotoMotion session."
        } else {
            bakedRigAnimationStatus = "No baked rig animation in session."
        }

        rotationOverrideLayer = document.rotationOverrideLayer
        selectedRotationJoint = document.selectedRotationJoint
        cleanRotationKeysEnabled = document.cleanRotationKeysEnabled
        rotationOverrideLayer.selectedJoint = selectedRotationJoint
        rotationOverrideLayer.cleanKeysEnabled = cleanRotationKeysEnabled
        heldRotationOverrideEulerXYZByJoint = simdHeldRotationOverrides(
            document.heldRotationOverrideEulerXYZByJoint
        )
        liveRotationOverrideEulerXYZByJoint = [:]
        liveRotationPreviewFrameIndexByJoint = [:]
        rotationOverrideRevision += 1
        isRotationGizmoDragging = false
        refreshSelectedJointEulerFields()

        rotationAuthoringStatus = "Loaded held rotation overrides."
    }

    static func verticalFOVFromHorizontalFOV(
        horizontalFOVDegrees: Double,
        aspectWidthOverHeight: Double
    ) -> Double {
        let horizontalRadians = horizontalFOVDegrees * .pi / 180.0
        let verticalRadians = 2.0 * atan(
            tan(horizontalRadians * 0.5) / aspectWidthOverHeight
        )

        return verticalRadians * 180.0 / .pi
    }

    static func horizontalFOVFromVerticalFOV(
        verticalFOVDegrees: Double,
        aspectWidthOverHeight: Double
    ) -> Double {
        let verticalRadians = verticalFOVDegrees * .pi / 180.0
        let horizontalRadians = 2.0 * atan(
            tan(verticalRadians * 0.5) * aspectWidthOverHeight
        )

        return horizontalRadians * 180.0 / .pi
    }

    func updateActiveCameraIntrinsicsForSpatialVideo() {
        let metadata = effectiveSpatialMetadata()

        guard let horizontalFOV = metadata.horizontalFOVDegrees,
              metadata.imageWidth > 0,
              metadata.imageHeight > 0 else {
            diagnostics.log("Spatial camera intrinsics update failed: missing metadata.")
            return
        }

        let aspect = Double(metadata.imageWidth) / Double(metadata.imageHeight)
        let verticalFOV = Self.verticalFOVFromHorizontalFOV(
            horizontalFOVDegrees: horizontalFOV,
            aspectWidthOverHeight: aspect
        )

        activeCameraIntrinsics = RotoCameraIntrinsics(
            source: useManualSpatialCameraOverrides
                ? "spatial video manual override landscape"
                : "spatial video metadata landscape",
            imageWidth: metadata.imageWidth,
            imageHeight: metadata.imageHeight,
            horizontalFOVDegrees: horizontalFOV,
            verticalFOVDegrees: verticalFOV,
            baselineMeters: metadata.baselineMeters
        )
        activeCameraProfileSource = .spatialVideoMetadata

        diagnostics.log("""
        Active camera profile switched to spatial landscape:
          source: \(activeCameraIntrinsics.source)
          imageSize: \(metadata.imageWidth)x\(metadata.imageHeight)
          horizontalFOV: \(String(format: "%.3f", horizontalFOV))
          verticalFOV: \(String(format: "%.3f", verticalFOV))
          baselineMeters: \(metadata.baselineMeters.map { String(format: "%.6f", $0) } ?? "nil")
          manualOverride: \(useManualSpatialCameraOverrides)
        """)
    }

    func updateActiveCameraIntrinsicsForMonocularVideo(
        imageWidth: Int,
        imageHeight: Int
    ) {
        let width = max(imageWidth, 1)
        let height = max(imageHeight, 1)
        let verticalFOV = activeCameraFOVDegrees
        let aspect = Double(width) / Double(height)
        let horizontalFOV = Self.horizontalFOVFromVerticalFOV(
            verticalFOVDegrees: verticalFOV,
            aspectWidthOverHeight: aspect
        )

        activeCameraIntrinsics = RotoCameraIntrinsics(
            source: "monocular vertical default",
            imageWidth: width,
            imageHeight: height,
            horizontalFOVDegrees: horizontalFOV,
            verticalFOVDegrees: verticalFOV,
            baselineMeters: nil
        )
        activeCameraProfileSource = .monocularVerticalProfile

        diagnostics.log("""
        Active camera profile set to monocular vertical:
          imageSize: \(width)x\(height)
          horizontalFOV: \(String(format: "%.3f", horizontalFOV))
          verticalFOV: \(String(format: "%.3f", verticalFOV))
        """)
    }

    private func updateActiveCameraIntrinsicsForCurrentMonocularFrame() {
        let size = currentVideoFrameImage?.size ?? decodedFrames.first?.image.size
        let width = max(Int((size?.width ?? 1080).rounded()), 1)
        let height = max(Int((size?.height ?? 1920).rounded()), 1)

        updateActiveCameraIntrinsicsForMonocularVideo(
            imageWidth: width,
            imageHeight: height
        )
    }

    var frameCount: Int {
        [
            decodedFrames.count,
            rawCapture?.frames.count,
            normalizedCapture?.frames.count,
            smoothedCapture?.frames.count,
            fitResult?.frames.count
        ]
        .compactMap { $0 }
        .max() ?? 0
    }

    var hasVideoURL: Bool {
        videoURL != nil
    }

    var hasDecodedFrames: Bool {
        !decodedFrames.isEmpty
    }

    var hasCurrentImage: Bool {
        currentVideoFrameImage != nil
    }

    var hasRawVision: Bool {
        rawCapture != nil && !(rawCapture?.frames.isEmpty ?? true)
    }

    var hasNormalizedMeshy24: Bool {
        normalizedCapture != nil && !(normalizedCapture?.frames.isEmpty ?? true)
    }

    var hasSmoothedMeshy24: Bool {
        smoothedCapture != nil && !(smoothedCapture?.frames.isEmpty ?? true)
    }

    var hasRigGeometry: Bool {
        (importedRigScene?.geometryNodeCount ?? 0) > 0
    }

    var hasMatchedRigJoints: Bool {
        !(importedRigScene?.skeletonJointNames.isEmpty ?? true)
    }

    var runVisionDisabledReason: String? {
        if videoURL == nil { return "No video URL selected." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var normalizeDisabledReason: String? {
        if rawCapture == nil { return "No raw Vision capture." }
        if rawCapture?.frames.isEmpty == true { return "Raw Vision capture has 0 frames." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var smoothingDisabledReason: String? {
        if normalizedCapture == nil { return "No normalized Meshy24 capture." }
        if normalizedCapture?.frames.isEmpty == true { return "Normalized Meshy24 has 0 frames." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var exportDisabledReason: String? {
        if smoothedCapture == nil && normalizedCapture == nil {
            return "No normalized or smoothed capture."
        }
        return nil
    }

    var currentRawFrame: RawVisionPoseCapture.PoseFrame? {
        nearestRawFrame(forTime: currentVideoTimeSeconds)
    }

    var currentNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        nearestNormalizedFrame(forTime: currentVideoTimeSeconds)
    }

    var currentRightRawFrame: RawVisionPoseCapture.PoseFrame? {
        guard captureMode == .spatialVideo,
              let frames = rawRightVisionCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentRightNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        guard captureMode == .spatialVideo,
              let frames = normalizedRightCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var shouldShowRightEyeVisionOverlay: Bool {
        captureMode == .spatialVideo &&
        !(rawRightVisionCapture?.frames.isEmpty ?? true)
    }

    var shouldShowRightEyeNormalizedOverlay: Bool {
        captureMode == .spatialVideo &&
        !(normalizedRightCapture?.frames.isEmpty ?? true)
    }

    var currentStereoJointFrame: StereoMeshyJointCapture.Frame? {
        guard spatialStereoAvailable,
              let frames = stereoJointCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentStereoTargetFrame: StereoMeshyJointCapture.Frame? {
        guard let frames = stereoJointCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentConditionedStereoFrame: ConditionedStereoJointCapture.Frame? {
        guard let frames = conditionedStereoJointCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentSpatialDisparityFrame: SpatialDisparityMapCapture.Frame? {
        guard let frames = spatialDisparityMapCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentSpatialDisparityPreviewFrame: SpatialDisparityPreviewCapture.Frame? {
        guard let frames = spatialDisparityPreviewCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentJointDepthEvidenceFrame: JointDepthEvidenceCapture.Frame? {
        guard let frames = jointDepthEvidenceCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentFusedStereoTargetFrame: FusedStereoJointTargetCapture.Frame? {
        guard let frames = fusedStereoJointTargetCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    func updateSpatialSolveReadiness() {
        guard captureMode == .spatialVideo else {
            spatialSolveReadiness = .notSpatial
            spatialSolveStatus = "Monocular mode."
            return
        }

        guard normalizedLeftCapture != nil else {
            spatialSolveReadiness = .needsVision
            spatialSolveStatus = "Spatial solve needs left-eye Vision."
            return
        }

        guard spatialDisparityMapCapture != nil else {
            spatialSolveReadiness = .needsDisparityMap
            spatialSolveStatus = "Spatial solve needs disparity map before solving."
            return
        }

        guard jointDepthEvidenceCapture != nil else {
            spatialSolveReadiness = .needsJointDepthEvidence
            spatialSolveStatus = "Spatial solve needs joint depth evidence before solving."
            return
        }

        spatialSolveReadiness = .ready
        spatialSolveStatus = "Spatial solve ready: left-eye rays + disparity depth."
    }

    func calibrateStereoToRigAlignmentIfPossible() {
        guard let session = skinnedRigSession else {
            stereoToRigAlignment = .invalid
            stereoAlignmentStatus = "Stereo alignment skipped: no skinned rig session."
            diagnostics.log(stereoAlignmentStatus)
            return
        }

        guard let frame = conditionedStereoJointCapture?.frames.first else {
            stereoToRigAlignment = .invalid
            stereoAlignmentStatus = "Stereo alignment skipped: no conditioned stereo frame."
            diagnostics.log(stereoAlignmentStatus)
            return
        }

        guard let alignment = StereoToRigAlignmentSolver.solveInitialAlignment(
            stereoFrame: frame,
            session: session
        ) else {
            stereoToRigAlignment = .invalid
            stereoAlignmentStatus = "Stereo alignment failed: not enough matching joints."
            diagnostics.log(stereoAlignmentStatus)
            return
        }

        stereoToRigAlignment = alignment
        stereoAlignmentStatus = """
        Stereo-to-rig alignment calibrated:
          scale: \(alignment.scale)
          translation: \(alignment.translation.simdFloat)
          rotationYRadians: \(alignment.rotationYRadians)
        """
        diagnostics.log(stereoAlignmentStatus)
    }

    private func invalidateStereoToRigAlignment(_ reason: String) {
        stereoToRigAlignment = .invalid
        stereoAlignmentStatus = "Stereo-to-rig alignment not calibrated: \(reason)"
        diagnostics.log(stereoAlignmentStatus)
    }

    var currentSmoothedFrame: SmoothedMeshyPoseCapture.Frame? {
        nearestSmoothedFrame(forTime: currentVideoTimeSeconds)
    }

    var currentFitFrame: RigFitResult.FrameFit? {
        guard let frames = fitResult?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == currentFrameIndex }
            ?? (frames.indices.contains(currentFrameIndex) ? frames[currentFrameIndex] : nil)
    }

    var currentRaySolvedFrame: RotoRayAnimationSolveResult.Frame? {
        guard let frames = rayAnimationSolveResult?.frames,
              !frames.isEmpty else {
            return nil
        }

        let time = currentVideoTimeSeconds

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    var currentVideoTimeSeconds: Double {
        guard decodedFrames.indices.contains(currentFrameIndex) else {
            return currentTimeSeconds
        }

        return decodedFrames[currentFrameIndex].timeSeconds
    }

    private func nearestRawFrame(
        forTime time: Double
    ) -> RawVisionPoseCapture.PoseFrame? {
        guard let frames = rawCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func nearestNormalizedFrame(
        forTime time: Double
    ) -> NormalizedMeshyPoseCapture.Frame? {
        guard let frames = normalizedCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func nearestSmoothedFrame(
        forTime time: Double
    ) -> SmoothedMeshyPoseCapture.Frame? {
        guard let frames = smoothedCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func calibratedRayReferenceArmature() -> RotoReferenceArmature {
        if let referenceRigProfile {
            diagnostics.log("""
            Using reference USDZ skeleton profile for solve.
            Manual height scaling disabled.
            unitScaleToMeters: \(referenceRigProfile.unitScaleToMeters ?? 1.0)
            estimatedHeightMeters: \(referenceRigProfile.estimatedHeightMeters ?? -1)
            sceneUnitsPerMeter: \(raySceneUnitsPerMeter)
            """)
            return RotoReferenceArmature.fromUSDZProfile(
                referenceRigProfile,
                sceneUnitsPerMeter: raySceneUnitsPerMeter
            )
        }

        let targetMeters = max(rayTargetHeightMeters, 0.0001)
        let sceneUnitsPerMeter = max(raySceneUnitsPerMeter, 0.0001)
        let targetSceneHeight = targetMeters * sceneUnitsPerMeter
        let scale = targetSceneHeight / RotoReferenceArmature.meshy24Default.restHeight

        return RotoReferenceArmature.meshy24Default.scaled(by: scale)
    }

    private func captureSessionSkeletonIdentity(from profile: USDZSkeletonProfile) {
        sessionSkeletonPath = profile.skeletonPath
        sessionJointPaths = profile.jointPaths
        sessionJointLeafNames = profile.jointLeafNames

        sessionSkeletonStatus = """
        Session skeleton captured:
        \(profile.skeletonPath)
        joints: \(profile.jointPaths.count)
        """

        diagnostics.log(sessionSkeletonStatus)
    }

    private func captureCanonicalSessionSkeletonIdentity() {
        sessionSkeletonPath = nil
        sessionJointPaths = CanonicalRig.jointPaths
        sessionJointLeafNames = CanonicalRig.jointNames
        sessionSkeletonStatus = "Session is using canonical Meshy24 fallback armature, not USDZ skeleton."
        diagnostics.log(sessionSkeletonStatus)
    }

    private func checkedOpenUSDPythonForRetarget(
        requireUSDZip: Bool = false
    ) -> String? {
        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        guard toolStatus.pythonOK,
              let pythonExecutablePath = toolStatus.pythonExecutablePath else {
            usdzRetargetStatus = """
            OpenUSD Python missing.
            \(toolStatus.pythonMessage)
            """
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return nil
        }

        if requireUSDZip && !toolStatus.usdzipOK {
            usdzRetargetStatus = "usdzip missing. Cannot export animated target USDZ."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return nil
        }

        return pythonExecutablePath
    }

    var videoSize: CGSize {
        if let project {
            return project.metadata.naturalSize
        }

        if let source = rawCapture?.sourceVideo {
            return CGSize(width: source.naturalWidth, height: source.naturalHeight)
        }

        return CGSize(width: 16, height: 9)
    }

    var durationText: String {
        guard let duration = project?.metadata.durationSeconds, duration.isFinite else {
            return "--"
        }

        return TimecodeFormatter.timecode(seconds: duration)
    }

    var fpsText: String {
        guard let fps = project?.metadata.nominalFrameRate, fps > 0 else {
            return "--"
        }

        return String(format: "%.2f", fps)
    }

    var sizeText: String {
        guard let project else {
            return "--"
        }

        return "\(Int(project.metadata.naturalSize.width.rounded())) x \(Int(project.metadata.naturalSize.height.rounded()))"
    }

    var detectedFrameText: String {
        guard let frames = rawCapture?.frames else {
            return "0"
        }

        return "\(frames.filter(\.detected).count)"
    }

    var currentTimelineText: String {
        if let frame = currentRawFrame {
            return "\(frame.timecode)  |  \(String(format: "%.3f", frame.timeSeconds))s"
        }

        if !decodedFrames.isEmpty {
            let frameIndex = min(max(currentFrameIndex, 0), decodedFrames.count - 1)
            let seconds = decodedFrames[frameIndex].timeSeconds
            return "\(TimecodeFormatter.timecode(seconds: seconds))  |  \(String(format: "%.3f", seconds))s"
        }

        return "\(TimecodeFormatter.timecode(seconds: currentTimeSeconds))  |  \(String(format: "%.3f", currentTimeSeconds))s"
    }

    var currentFitScoreText: String {
        guard let score = currentFitFrame?.fitScore else {
            return "--"
        }

        return String(format: "%.3f", score)
    }

    var averageFitErrorText: String {
        guard let frame = currentFitFrame, !frame.fitErrors.isEmpty else {
            return "--"
        }

        let average = frame.fitErrors.values.reduce(0, +) / Double(frame.fitErrors.count)
        return String(format: "%.4f", average)
    }

    func solveCurrentFrameRays(videoPlaneSize: CGSize) {
        guard let normalizedFrame = currentNormalizedFrame else {
            raySolveStatus = "Cannot solve rays: no normalized Meshy24 frame."
            diagnostics.log(raySolveStatus)
            return
        }

        let result = RotoRayRigSolver.solveFrame(
            frameIndex: currentFrameIndex,
            normalizedFrame: normalizedFrame,
            armature: calibratedRayReferenceArmature(),
            cameraOrigin: SIMD3<Float>(0, 0, cameraZ),
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: currentVideoPlaneZ,
            solveMode: raySolveMode.solverMode,
            rayLength: Float(rayLength)
        )

        currentRaySolveResult = result
        raySolveStatus = """
        Ray solve complete.
        frame: \(currentFrameIndex)
        mode: \(raySolveMode.displayName)
        joints: \(result.joints.count)
        rays: \(result.rays.count)
        errors: \(result.errors.count)
        """

        diagnostics.log(raySolveStatus)
    }

    private func clampedBetweenCameraAndImagePlane(_ z: Float) -> Float {
        min(cameraZ - 0.25, max(z, currentVideoPlaneZ + 1.0))
    }

    private func updateReferenceRigPlacementStatus(
        rigZ: Float,
        context: String
    ) {
        let invariant = currentVideoPlaneZ < rigZ && rigZ < cameraZ
        referenceRigPlacementStatus = """
        Reference Rig Placement:
        camera \(String(format: "%.1f", cameraZ))
        rig \(String(format: "%.3f", rigZ))
        image plane \(String(format: "%.1f", currentVideoPlaneZ))
        status: between camera and plane \(invariant ? "YES" : "NO")
        """

        diagnostics.log("""
        \(context):
          cameraZ: \(cameraZ)
          rigZ: \(rigZ)
          imagePlaneZ: \(currentVideoPlaneZ)
          invariant: \(invariant)
        """)
    }

    func autoCalibrateRigDepth() {
        guard let frame = currentNormalizedFrame else {
            depthCalibrationStatus = "Normalize Meshy24 before depth calibration."
            status = depthCalibrationStatus
            diagnostics.log(depthCalibrationStatus)
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            depthCalibrationStatus = "No video plane size available."
            status = depthCalibrationStatus
            diagnostics.log(depthCalibrationStatus)
            return
        }

        let referenceArmature = calibratedRayReferenceArmature()

        guard let result = RotoDepthCalibrator.calibrateHipsToSpine(
            normalizedFrame: frame,
            armature: referenceArmature,
            cameraOrigin: SIMD3<Float>(0, 0, cameraZ),
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: currentVideoPlaneZ,
            nearZ: -0.25,
            initialFarZ: referenceRigDefaultZ,
            maxFarZ: currentVideoPlaneZ + 1.0
        ) else {
            depthCalibrationStatus = "Depth calibration failed: missing Hips/Spine or reference Hips<->Spine bone."
            status = depthCalibrationStatus
            diagnostics.log(depthCalibrationStatus)
            return
        }

        let clampedZ = clampedBetweenCameraAndImagePlane(result.depthZ)
        calibratedRigDepthZ = Double(clampedZ)
        projectionScaleError = Double(result.error)
        useCalibratedRigDepth = true
        referenceRigCurrentZ = clampedZ
        updateReferenceRigPlacementStatus(
            rigZ: clampedZ,
            context: "Depth placement"
        )

        depthCalibrationStatus = """
        Depth calibrated from Hips<->Spine:
        z \(String(format: "%.3f", calibratedRigDepthZ))
        solvedZ \(String(format: "%.3f", result.depthZ))
        error \(String(format: "%.5f", projectionScaleError))
        target2D \(String(format: "%.4f", result.targetBoneLength2D))
        projected2D \(String(format: "%.4f", result.projectedBoneLength2D))
        ref3D \(String(format: "%.4f", result.referenceBoneLength3D))
        """
        status = depthCalibrationStatus
        diagnostics.log(depthCalibrationStatus)
    }

    func solveFullAnimationWithCameraRays() async {
        if captureMode == .spatialVideo {
            await solveFullSpatialRayPinningWithDisparityOrFallback()
            return
        }

        guard let normalizedCapture else {
            rayAnimationSolveStatus = "Normalize Meshy24 before ray solve."
            status = rayAnimationSolveStatus
            diagnostics.log(rayAnimationSolveStatus)
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            rayAnimationSolveStatus = "No video plane size available."
            status = rayAnimationSolveStatus
            diagnostics.log(rayAnimationSolveStatus)
            return
        }

        if let referenceRigProfile {
            captureSessionSkeletonIdentity(from: referenceRigProfile)
        } else {
            captureCanonicalSessionSkeletonIdentity()
        }

        let referenceArmature = calibratedRayReferenceArmature()
        var rootDepthZ: Float? = clampedBetweenCameraAndImagePlane(referenceRigDefaultZ)
        referenceRigCurrentZ = rootDepthZ ?? referenceRigDefaultZ
        updateReferenceRigPlacementStatus(
            rigZ: referenceRigCurrentZ,
            context: "Reference rig default solve placement"
        )

        if let calibrationFrame = currentNormalizedFrame,
           let depth = RotoDepthCalibrator.calibrateHipsToSpine(
               normalizedFrame: calibrationFrame,
               armature: referenceArmature,
               cameraOrigin: SIMD3<Float>(0, 0, cameraZ),
               videoPlaneSize: videoPlaneSize,
               videoPlaneZ: currentVideoPlaneZ,
               nearZ: -0.25,
               initialFarZ: referenceRigDefaultZ,
               maxFarZ: currentVideoPlaneZ + 1.0
           ) {
            let clampedZ = clampedBetweenCameraAndImagePlane(depth.depthZ)
            calibratedRigDepthZ = Double(clampedZ)
            projectionScaleError = Double(depth.error)
            useCalibratedRigDepth = true
            rootDepthZ = clampedZ
            referenceRigCurrentZ = clampedZ
            updateReferenceRigPlacementStatus(
                rigZ: clampedZ,
                context: "Depth placement"
            )
            depthCalibrationStatus = """
            Auto depth from Hips<->Spine:
            z \(String(format: "%.3f", calibratedRigDepthZ))
            solvedZ \(String(format: "%.3f", depth.depthZ))
            error \(String(format: "%.5f", projectionScaleError))
            target2D \(String(format: "%.4f", depth.targetBoneLength2D))
            projected2D \(String(format: "%.4f", depth.projectedBoneLength2D))
            ref3D \(String(format: "%.4f", depth.referenceBoneLength3D))
            """
        } else {
            useCalibratedRigDepth = false
            rootDepthZ = clampedBetweenCameraAndImagePlane(referenceRigDefaultZ)
            referenceRigCurrentZ = rootDepthZ ?? referenceRigDefaultZ
            updateReferenceRigPlacementStatus(
                rigZ: referenceRigCurrentZ,
                context: "Depth placement fallback"
            )
            depthCalibrationStatus = "Auto depth failed: missing Hips/Spine or reference Hips<->Spine bone. Solving at default reference rig depth."
        }

        diagnostics.log(depthCalibrationStatus)

        var solverSettings = RotoRayConstrainedIKSolver.Settings.default
        solverSettings.forceCameraFacingYaw = forceCameraFacingYaw

        let result = RotoRayAnimationSolver.solveAnimation(
            normalized: normalizedCapture,
            videoPlaneSize: videoPlaneSize,
            mode: raySolveMode.animationSolverMode,
            targetHeightMeters: rayTargetHeightMeters,
            sceneUnitsPerMeter: raySceneUnitsPerMeter,
            referenceArmature: referenceArmature,
            rootDepthZ: rootDepthZ,
            cameraOrigin: SIMD3<Float>(0, 0, cameraZ),
            videoPlaneZ: currentVideoPlaneZ,
            settings: solverSettings
        )

        rayAnimationSolveResult = result
        applySolvedPoseToReferenceRig = true
        showSkinnedRig = true
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Solve changed. Bake rig animation before export."

        if skinnedRigSession != nil {
            sessionPoseSource = .posedArmatureLocalTransforms
            sessionPoseStatus = """
            The actual skinned rig is rotomated to locked 3D joint positions.
            Local rotations are sampled from the posed rig after positions are fitted.
            """
        } else {
            sessionPoseSource = .drawnJointPositions
            sessionPoseStatus = """
            Viewport solved rig is drawn from rayAnimationSolveResult.frame.jointPositions.
            It is green debug geometry, not a posed SceneKit/USD armature local-transform stack.
            """
        }
        currentRaySolveResult = nil
        raySolveStatus = "Single-frame ray solve cleared."
        rayAnimationSolveStatus = "Solved \(result.frames.count) frames at \(String(format: "%.2f", result.targetHeightMeters)) m."
        status = rayAnimationSolveStatus
        diagnostics.log("""
        Solve Full Animation complete. Actual rig rotomation enabled:
          applySolvedPoseToReferenceRig: \(applySolvedPoseToReferenceRig)
          solvedFrames: \(result.frames.count)
          currentFrame: \(currentFrameIndex)
          currentRaySolvedFrame exists: \(currentRaySolvedFrame != nil)
        """)
        diagnostics.log("""
        Ray animation solve complete:
          frames: \(result.frames.count)
          mode: \(raySolveMode.displayName)
          targetHeightMeters: \(String(format: "%.3f", result.targetHeightMeters))
          sceneUnitsPerMeter: \(String(format: "%.3f", result.sceneUnitsPerMeter))
          armatureSceneScale: \(String(format: "%.3f", result.armatureSceneScale))
          referenceUSDZ: \(referenceSolveUSDZURL?.lastPathComponent ?? "none")
          rootDepthZ: \(rootDepthZ.map { String(format: "%.3f", $0) } ?? "videoPlane")
          forceCameraFacingYaw: \(forceCameraFacingYaw)
          sessionPoseSource: \(sessionPoseSource.rawValue)
          videoPlaneSize: \(videoPlaneSize)
          firstSolvedJoints: \(result.frames.first?.solvedJoints.count ?? 0)

        Session pose source:
          \(sessionPoseSource.rawValue)

        If drawnJointPositions:
          viewport match does not guarantee skinned USDZ export.
        If posedArmatureLocalTransforms:
          export should serialize exact local transforms.
        """)
    }

    func solveFullSpatialRayPinningWithDisparityOrFallback() async {
        guard normalizedLeftCapture != nil else {
            applySolvedPoseToReferenceRig = false
            rayAnimationSolveStatus = "Spatial solve blocked: run Vision on the left eye first."
            status = rayAnimationSolveStatus

            diagnostics.log("""
            Spatial solve blocked:
              reason: normalizedLeftCapture missing.
              action: Run Vision first.
            """)
            return
        }

        guard !isBuildingSpatialDisparity else {
            applySolvedPoseToReferenceRig = false
            rayAnimationSolveStatus = "Spatial solve blocked: disparity build already in progress."
            status = rayAnimationSolveStatus

            diagnostics.log("""
            Spatial solve blocked:
              reason: disparity build is already running.
              action: wait for Spatial disparity build SUCCESS or FAILED before solving.
            """)
            return
        }

        spatialSolveProgressFraction = 0
        var preparingTrace = SpatialSolveTrace()
        preparingTrace.phase = .preparing
        preparingTrace.solveTargetMode = solveTargetMode.rawValue
        preparingTrace.depthMode = spatialRayPinDepthMode.rawValue
        preparingTrace.depthEvidenceJoints = jointDepthEvidenceCapture?.frames.first?.joints.count ?? 0
        preparingTrace.message = "Preparing spatial ray-pinned solve."
        updateSpatialSolveTrace(preparingTrace)
        spatialSolveProgressTitle = "Spatial Solve Preparing"
        spatialSolveProgressDetail = """
        mode: \(spatialRayPinDepthMode.rawValue)
        left frames: \(normalizedLeftCapture?.frames.count ?? 0)
        disparity frames: \(spatialDisparityMapCapture?.frames.count ?? 0)
        evidence frames: \(jointDepthEvidenceCapture?.frames.count ?? 0)
        """

        var disparityOK = spatialDisparityMapCapture != nil &&
            spatialDisparityPreviewCapture != nil &&
            jointDepthEvidenceCapture != nil

        if !disparityOK {
            diagnostics.log("""
            Spatial solve preparing disparity:
              currentDisparityFrames: \(spatialDisparityMapCapture?.frames.count ?? 0)
              currentPreviewFrames: \(spatialDisparityPreviewCapture?.frames.count ?? 0)
              currentEvidenceFrames: \(jointDepthEvidenceCapture?.frames.count ?? 0)
            """)

            disparityOK = await buildSpatialDisparityMaps()
        }

        if disparityOK {
            spatialRayPinDepthMode = .disparityDepthGuided
            diagnostics.log("""
            Spatial solve using disparity-depth-guided left-eye ray pinning.
              disparityFrames: \(spatialDisparityMapCapture?.frames.count ?? 0)
              previewFrames: \(spatialDisparityPreviewCapture?.frames.count ?? 0)
              evidenceFrames: \(jointDepthEvidenceCapture?.frames.count ?? 0)
              disparityOverlayVisible: \(showDisparityOnImagePlane)
            """)
        } else {
            spatialRayPinDepthMode = .leftEyeRayPinningFallback
            diagnostics.log("""
            Spatial solve falling back to LEFT-EYE RAY PINNING ONLY.
              reason: disparity build failed or produced no evidence.
              this is explicit fallback, not hidden.
            """)
        }

        if let referenceRigProfile {
            captureSessionSkeletonIdentity(from: referenceRigProfile)
        } else {
            captureCanonicalSessionSkeletonIdentity()
        }

        solveTargetMode = .spatialDepthGuidedRayPinned
        applySolvedPoseToReferenceRig = true
        showSkinnedRig = true
        currentRaySolveResult = nil
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Spatial depth-guided ray-pinned solve changed. Bake rig animation before export."
        sessionPoseSource = .posedArmatureLocalTransforms
        sessionPoseStatus = """
        The actual skinned rig is rotomated live from depth-guided ray pins.
        Left-eye Vision supplies rays; disparity evidence chooses depth along each ray.
        """
        raySolveStatus = "Single-frame ray solve cleared."
        rayAnimationSolveStatus = "Spatial depth-guided ray-pinning solve enabled."
        spatialSolveStatus = """
        Spatial solve active:
          mode: \(spatialRayPinDepthMode.rawValue)
          solveTargetMode: \(solveTargetMode.rawValue)
        """
        spatialSolveTrace.solveTargetMode = solveTargetMode.rawValue
        spatialSolveTrace.depthMode = spatialRayPinDepthMode.rawValue
        status = rayAnimationSolveStatus
        solveInputRevision &+= 1
        requestViewportRefresh(reason: "spatial solve mode changed \(spatialRayPinDepthMode.rawValue)")

        diagnostics.log("""
        Solve Full Animation using LEFT-EYE ray pinning:
          solveTargetMode: \(solveTargetMode.rawValue)
          spatialRayPinDepthMode: \(spatialRayPinDepthMode.rawValue)
          leftNormalizedFrames: \(normalizedLeftCapture?.frames.count ?? 0)
          disparityFrames: \(spatialDisparityMapCapture?.frames.count ?? 0)
          disparityPreviewFrames: \(spatialDisparityPreviewCapture?.frames.count ?? 0)
          jointDepthEvidenceFrames: \(jointDepthEvidenceCapture?.frames.count ?? 0)
          usesLeftEyeRays: true
          usesRightEyeForRayPinning: false
          usesDisparityDepthGuidance: \(spatialRayPinDepthMode == .disparityDepthGuided)
          usesDirectStereoPoints: false
          usesConditionedStereoPointCloud: false
          usesMetersToSceneUnits: false
          usesHipsSpineInitialFit: false
        """)
    }

    func loadSkinnedRigUSDZ() {
        guard let url = FilePanelHelpers.openUSDZURL() else {
            skinnedRigStatus = "Skinned rig selection canceled."
            status = skinnedRigStatus
            diagnostics.log(skinnedRigStatus)
            return
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let unitScale = Float(referenceRigProfile?.unitScaleToMeters ?? 0.01)
            let session = try SkinnedUSDZRigLoader.load(
                url: url,
                unitScaleToMeters: unitScale,
                sceneUnitsPerMeter: Float(raySceneUnitsPerMeter),
                yawCorrectionRadians: 0,
                defaultRigZ: Float(referenceRigZ)
            )

            skinnedRigSession = session
            showSkinnedRig = true
            showSkinnedGeometry = true
            if targetCharacterUSDZURL == nil {
                targetCharacterUSDZURL = url
            }
            sessionArmaturePoseBuffer = nil
            bakedRigAnimation = nil
            bakedRigAnimationStatus = "Reference rig loaded. Bake rig animation before export."
            sessionArmatureSnapshot = nil
            referenceRigPlacementStatus = """
            Reference rig loaded.
            Default placement:
            position (0.000, -0.750, -2.000)
            scale (1.000, 1.000, 1.000)
            rotationX -90.0
            rotationY 360.0
            """
            referenceRigVisibilityStatus = "Reference rig loaded with hardcoded viewport placement."

            skinnedRigStatus = """
            Loaded skinned rig:
            \(url.lastPathComponent)
            matched bones: \(session.validBoneCount)
            """

            sessionPoseSource = .posedArmatureLocalTransforms
            sessionPoseStatus = """
            Viewport is using real SCNSkinner bone nodes.
            Export will sample these bone-node local transforms after baking.
            """

            status = skinnedRigStatus
            diagnostics.log(skinnedRigStatus)
            diagnostics.log(referenceRigPlacementStatus)
            diagnostics.log(sessionPoseStatus)

            fitReferenceRigHipsSpineIfPossible()
            calibrateStereoToRigAlignmentIfPossible()
            refreshSelectedJointEulerFields()
        } catch {
            skinnedRigSession = nil
            invalidateStereoToRigAlignment("skinned rig load failed")
            sessionArmaturePoseBuffer = nil
            bakedRigAnimation = nil
            bakedRigAnimationStatus = "Reference rig load failed. Bake unavailable."
            sessionArmatureSnapshot = nil
            sessionPoseSource = rayAnimationSolveResult == nil ? .none : .drawnJointPositions
            sessionPoseStatus = sessionPoseSource == .none
                ? "No session pose source detected."
                : "Ray solve viewport is drawn joint positions; skinned rig load failed."
            skinnedRigStatus = "Skinned rig load failed: \(error.localizedDescription)"
            status = skinnedRigStatus
            diagnostics.log(skinnedRigStatus)
        }
    }

    func bakeLiveRigAnimationForExport() {
        if captureMode == .spatialVideo,
           solveTargetMode == .spatialDepthGuidedRayPinned {
            bakeSpatialDepthGuidedRayPinnedRigAnimationForExport()
            return
        }

        guard let session = skinnedRigSession else {
            bakedRigAnimationStatus = "Load reference skinned rig first."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        guard let solve = rayAnimationSolveResult else {
            bakedRigAnimationStatus = "Run Solve Full Animation first."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            bakedRigAnimationStatus = "Video plane size unavailable. Show the viewport before baking."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        let savedRootPosition = session.displayRootNode.simdPosition
        let savedRootOrientation = session.displayRootNode.simdOrientation
        let savedRootScale = session.displayRootNode.simdScale
        let savedBoneTransforms = session.jointOrder.reduce(into: [String: simd_float4x4]()) { result, joint in
            if let bone = session.bonesByCanonicalName[joint] {
                result[joint] = bone.simdTransform
            }
        }

        defer {
            session.displayRootNode.simdPosition = savedRootPosition
            session.displayRootNode.simdOrientation = savedRootOrientation
            session.displayRootNode.simdScale = savedRootScale

            for (joint, transform) in savedBoneTransforms {
                session.bonesByCanonicalName[joint]?.simdTransform = transform
            }
        }

        let keyedSummary = rotationOverrideLayer.keyframesByJoint
            .filter { !$0.value.isEmpty }
            .map { joint, keys in
                "\(joint): \(keys.map { "\($0.frameIndex)" }.joined(separator: ","))"
            }
            .sorted()
            .joined(separator: " | ")

        diagnostics.log("""
        Bake rotation key input:
          keyed joints: \(keyedSummary.isEmpty ? "none" : keyedSummary)
          held override joints: \(heldRotationOverrideEulerXYZByJoint.keys.sorted().joined(separator: ","))
        """)

        let authoredJoints = authoredRotationJoints()
        diagnostics.log("""
        Bake authored rotation joints:
        \(authoredJoints.sorted().joined(separator: ", "))
        """)

        let selectedKeys = rotationOverrideLayer.keyframesByJoint[selectedRotationJoint] ?? []
        diagnostics.log("""
        Bake selected joint authored input:
          joint: \(selectedRotationJoint)
          keyCount: \(selectedKeys.count)
          keyFrames: \(selectedKeys.map { "\($0.frameIndex)" }.joined(separator: ", "))
          keyEulerXYZ: \(selectedKeys.map { "\($0.frameIndex):\($0.eulerXYZ)" }.joined(separator: " | "))
          authoredMode: \(selectedKeys.isEmpty ? "false" : "true")
        """)

        var frames: [BakedRigAnimation.Frame] = []
        let selectedKeyFrameSet = Set(selectedKeys.map { $0.frameIndex })
        var lastLoggedSelectedEuler: SIMD3<Float>?
        var evaluatedDebugFrames: [[String: Any]] = []
        var sampledDebugFrames: [[String: Any]] = []

        for solvedFrame in solve.frames {
            guard let normalizedFrame = normalizedFrameClosestTo(
                timeSeconds: solvedFrame.timeSeconds
            ) else {
                continue
            }

            SkinnedRigRotomationDriver.rotomateFrameWithCurvePins(
                solvedFrame,
                normalizedFrame: normalizedFrame,
                session: session,
                cameraOrigin: SIMD3<Float>(0, 0, 0),
                videoPlaneSize: videoPlaneSize,
                videoPlaneZ: currentVideoPlaneZ
            )

            let selectedEulerForFrame = authoredJoints.contains(selectedRotationJoint)
                ? authoredEulerForFrame(
                    joint: selectedRotationJoint,
                    frameIndex: solvedFrame.frameIndex
                )
                : nil

            var shouldLogSelectedSample = false

            if let euler = selectedEulerForFrame {
                evaluatedDebugFrames.append([
                    "frame": solvedFrame.frameIndex,
                    "time": solvedFrame.timeSeconds,
                    "euler": [
                        Double(euler.x),
                        Double(euler.y),
                        Double(euler.z)
                    ]
                ])

                let didChange = lastLoggedSelectedEuler.map { previous in
                    simd_length(euler - previous) > 0.0001
                } ?? true

                if didChange || selectedKeyFrameSet.contains(solvedFrame.frameIndex) {
                    diagnostics.log("""
                    Bake authored replacement:
                      joint: \(selectedRotationJoint)
                      frame: \(solvedFrame.frameIndex)
                      time: \(String(format: "%.4f", solvedFrame.timeSeconds))
                      eulerXYZ: \(euler)
                    """)
                    lastLoggedSelectedEuler = euler
                    shouldLogSelectedSample = true
                }
            }

            var bakedFrame = BakedRigAnimationSampler.sample(
                session: session,
                frameIndex: solvedFrame.frameIndex,
                timeSeconds: solvedFrame.timeSeconds,
                jointNames: session.jointOrder
            )

            bakedFrame = replaceAuthoredJointRotations(
                bakedFrame,
                authoredJoints: authoredJoints,
                frameIndex: solvedFrame.frameIndex,
                timeSeconds: solvedFrame.timeSeconds
            )

            frames.append(bakedFrame)

            if let joint = bakedFrame.joints[selectedRotationJoint] {
                sampledDebugFrames.append([
                    "frame": bakedFrame.frameIndex,
                    "time": bakedFrame.timeSeconds,
                    "localRotationEulerXYZ": joint.localRotationEulerXYZ
                ])

                if shouldLogSelectedSample {
                    diagnostics.log("""
                    Bake sampled selected joint:
                      frame: \(bakedFrame.frameIndex)
                      localRotationEulerXYZ: \(joint.localRotationEulerXYZ)
                    """)
                }
            }
        }

        let baked = BakedRigAnimation(
            schema: "com.gravitas.rotomotion.baked_rig_animation.v0",
            clipID: retargetClipID,
            fps: inferredFPS(solve.frames),
            jointNames: session.jointOrder,
            frames: frames
        )

        writeBakeRotationOverrideDebugJSON(
            selectedKeys: selectedKeys,
            evaluatedFrames: evaluatedDebugFrames,
            sampledFrames: sampledDebugFrames
        )

        bakedRigAnimation = baked
        sessionArmaturePoseBuffer = baked.asSessionArmaturePoseBuffer()
        sessionPoseSource = .posedArmatureLocalTransforms
        sessionPoseStatus = "Baked immutable rig animation from live curve-pinned pose: \(frames.count) frames."
        bakedRigAnimationStatus = "Baked \(frames.count) frames with rotation override keys."
        usdzRetargetStatus = bakedRigAnimationStatus
        status = bakedRigAnimationStatus
        diagnostics.log(bakedRigAnimationStatus)
    }

    func bakeSpatialDepthGuidedRayPinnedRigAnimationForExport() {
        guard let session = skinnedRigSession else {
            bakedRigAnimationStatus = "Spatial bake failed: no skinned rig session."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        guard let leftCapture = normalizedLeftCapture,
              !leftCapture.frames.isEmpty else {
            bakedRigAnimationStatus = "Spatial bake failed: no normalized left-eye capture."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            bakedRigAnimationStatus = "Spatial bake failed: no current video plane size."
            status = bakedRigAnimationStatus
            diagnostics.log(bakedRigAnimationStatus)
            return
        }

        if spatialRayPinDepthMode == .disparityDepthGuided {
            guard let evidence = jointDepthEvidenceCapture,
                  !evidence.frames.isEmpty else {
                bakedRigAnimationStatus = "Spatial bake failed: disparityDepthGuided mode requires joint depth evidence."
                status = bakedRigAnimationStatus
                diagnostics.log(bakedRigAnimationStatus)
                return
            }
        }

        bakeSpatialDepthGuidedRayPinnedRigAnimationForExport(
            session: session,
            leftCapture: leftCapture,
            videoPlaneSize: videoPlaneSize
        )
    }

    private func bakeSpatialDepthGuidedRayPinnedRigAnimationForExport(
        session: SkinnedRigSession,
        leftCapture: NormalizedMeshyPoseCapture,
        videoPlaneSize: CGSize
    ) {
        let savedRootPosition = session.displayRootNode.simdPosition
        let savedRootOrientation = session.displayRootNode.simdOrientation
        let savedRootScale = session.displayRootNode.simdScale
        let savedBoneTransforms = session.jointOrder.reduce(into: [String: simd_float4x4]()) { result, joint in
            if let bone = session.bonesByCanonicalName[joint] {
                result[joint] = bone.simdTransform
            }
        }

        defer {
            session.displayRootNode.simdPosition = savedRootPosition
            session.displayRootNode.simdOrientation = savedRootOrientation
            session.displayRootNode.simdScale = savedRootScale

            for (joint, transform) in savedBoneTransforms {
                session.bonesByCanonicalName[joint]?.simdTransform = transform
            }
        }

        let authoredJoints = authoredRotationJoints()
        let authoredSummary = authoredJoints.sorted().joined(separator: ", ")
        var frames: [BakedRigAnimation.Frame] = []
        frames.reserveCapacity(leftCapture.frames.count)

        diagnostics.log("""
        Spatial bake START:
          mode: \(spatialRayPinDepthMode.rawValue)
          solveTargetMode: \(solveTargetMode.rawValue)
          leftFrames: \(leftCapture.frames.count)
          jointDepthEvidenceFrames: \(jointDepthEvidenceCapture?.frames.count ?? 0)
          authoredKeyedJoints: \(authoredSummary.isEmpty ? "none" : authoredSummary)
          usesLeftEyeRayPinning: true
          usesDisparityDepth: \(spatialRayPinDepthMode == .disparityDepthGuided)
          usesConditionedStereoPointCloud: false
          usesMetersToSceneUnits: false
        """)

        for (ordinal, normalizedFrame) in leftCapture.frames.enumerated() {
            let evidenceFrame = spatialRayPinDepthMode == .disparityDepthGuided
                ? nearestJointDepthEvidenceFrame(timeSeconds: normalizedFrame.timeSeconds)
                : nil

            SkinnedRigRotomationDriver.rotomateFrameWithDepthGuidedRayPins(
                normalizedFrame: normalizedFrame,
                jointDepthEvidenceFrame: evidenceFrame,
                depthMode: spatialRayPinDepthMode,
                session: session,
                cameraOrigin: SIMD3<Float>(0, 0, 0),
                videoPlaneSize: videoPlaneSize,
                videoPlaneZ: currentVideoPlaneZ,
                depthFitSettings: spatialRayPinDepthFitSettings,
                autoDepthFitEnabled: autoSpatialDepthFitEnabled,
                manualDepthZoom: Float(manualSpatialDepthZoom),
                manualDepthOffset: Float(manualSpatialDepthOffset)
            )

            applyRotationOverridesToRigForBakeFrame(
                session: session,
                frameIndex: normalizedFrame.frameIndex,
                timeSeconds: normalizedFrame.timeSeconds
            )

            var bakedFrame = BakedRigAnimationSampler.sample(
                session: session,
                frameIndex: normalizedFrame.frameIndex,
                timeSeconds: normalizedFrame.timeSeconds,
                jointNames: session.jointOrder
            )

            bakedFrame = replaceAuthoredJointRotations(
                bakedFrame,
                authoredJoints: authoredJoints,
                frameIndex: normalizedFrame.frameIndex,
                timeSeconds: normalizedFrame.timeSeconds
            )

            frames.append(bakedFrame)

            if normalizedFrame.frameIndex == 0 || normalizedFrame.frameIndex % 30 == 0 {
                diagnostics.log("""
                Spatial bake frame:
                  ordinal: \(ordinal + 1)/\(leftCapture.frames.count)
                  frameIndex: \(normalizedFrame.frameIndex)
                  time: \(String(format: "%.3f", normalizedFrame.timeSeconds))
                  evidence: \(evidenceFrame == nil ? "none" : "yes")
                """)
            }
        }

        for joint in authoredJoints.sorted() {
            let keys = rotationOverrideLayer.keyframesByJoint[joint] ?? []
            diagnostics.log("""
            Spatial bake authored key replacement:
              joint: \(joint)
              keyCount: \(keys.count)
              frames: \(keys.map { "\($0.frameIndex)" }.joined(separator: ", "))
            """)
        }

        let baked = BakedRigAnimation(
            schema: "com.gravitas.rotomotion.baked_rig_animation.v0",
            clipID: retargetClipID,
            fps: inferredFPSFromNormalizedFrames(leftCapture.frames),
            jointNames: session.jointOrder,
            frames: frames
        )

        bakedRigAnimation = baked
        sessionArmaturePoseBuffer = baked.asSessionArmaturePoseBuffer()
        sessionPoseSource = .posedArmatureLocalTransforms
        sessionPoseStatus = "Baked immutable rig animation from spatial depth-guided ray pins: \(frames.count) frames."
        bakedRigAnimationStatus = """
        Spatial bake complete:
          frames: \(frames.count)
          mode: \(spatialRayPinDepthMode.rawValue)
          authored keyed joints: \(authoredJoints.count)
        """
        usdzRetargetStatus = bakedRigAnimationStatus
        status = bakedRigAnimationStatus
        diagnostics.log(bakedRigAnimationStatus)
    }

    private func nearestJointDepthEvidenceFrame(
        timeSeconds: Double
    ) -> JointDepthEvidenceCapture.Frame? {
        guard let frames = jointDepthEvidenceCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private func writeBakeRotationOverrideDebugJSON(
        selectedKeys: [JointRotationOverrideLayer.Keyframe],
        evaluatedFrames: [[String: Any]],
        sampledFrames: [[String: Any]]
    ) {
        let inputKeys: [[String: Any]] = selectedKeys.map { key in
            [
                "frame": key.frameIndex,
                "time": key.timeSeconds,
                "eulerXYZ": key.eulerXYZ
            ]
        }

        let root: [String: Any] = [
            "selectedJoint": selectedRotationJoint,
            "inputKeys": inputKeys,
            "evaluatedFrames": evaluatedFrames,
            "sampledFrames": sampledFrames
        ]

        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bake_rotation_override_debug.json")
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )

            try data.write(to: url, options: .atomic)
            diagnostics.log("Wrote bake rotation override debug JSON: \(url.path)")
        } catch {
            diagnostics.log("Bake rotation override debug JSON failed: \(error.localizedDescription)")
        }
    }

    func bakeSessionArmaturePoseBuffer() {
        bakeLiveRigAnimationForExport()
    }

    func normalizedFrameClosestTo(
        timeSeconds: Double
    ) -> NormalizedMeshyPoseCapture.Frame? {
        guard let frames = normalizedCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private func exportTargetURLAvoidingViewportCopy(
        _ url: URL
    ) -> URL {
        guard let session = skinnedRigSession else {
            return url
        }

        let targetIsViewportCopy = url.standardizedFileURL == session.sourceURL.standardizedFileURL
        let viewportIsOriginal = session.sourceURL.standardizedFileURL == session.originalSourceURL.standardizedFileURL

        guard targetIsViewportCopy, !viewportIsOriginal else {
            return url
        }

        diagnostics.log("""
        Export target was the viewport-only reference copy. Using original USDZ instead.
          viewport source: \(session.sourceURL.path)
          export target: \(session.originalSourceURL.path)
        """)

        return session.originalSourceURL
    }

    private func inferredFPS(
        _ frames: [RotoRayAnimationSolveResult.Frame]
    ) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 24.0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }

    private func inferredFPSFromNormalizedFrames(
        _ frames: [NormalizedMeshyPoseCapture.Frame]
    ) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 24.0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }

    func openVideo() {
        diagnostics.log("Open Video requested.")

        guard let url = FilePanelHelpers.openVideoURL() else {
            diagnostics.log("Open Video canceled by user.")
            status = "Open video canceled."
            return
        }

        diagnostics.log("Selected video: \(url.path)")

        stopFramePlayback()
        releaseCurrentVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()

        videoSecurityScopedURL = url
        videoSecurityScopedAccessActive = didAccess

        videoURL = url
        lastLoadedVideoURL = url
        captureMode = .monocularVideo
        activeCameraProfileSource = .monocularVerticalProfile
        solveTargetMode = .monocularRayPinned
        clearSpatialVideoState(clearURL: true)
        outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        rawCapture = nil
        normalizedCapture = nil
        smoothedCapture = nil
        fitResult = nil
        project = nil
        lastVisionError = nil
        lastNormalizeError = nil
        lastSmoothingError = nil
        currentRaySolveResult = nil
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        resetRotationAuthoringForNewSession()
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Reference changed. Bake rig animation before export."
        sessionPoseSource = .none
        sessionPoseStatus = "No session pose source detected."
        currentVideoPlaneSize = nil
        useCalibratedRigDepth = false
        calibratedRigDepthZ = 0
        projectionScaleError = 0
        depthCalibrationStatus = "Depth calibration not run."
        raySolveStatus = "Ray solve not run."
        rayAnimationSolveStatus = "Ray animation solve not run."
        raySolvedUSDZExportStatus = "No ray solve USDZ exported."
        usdzRetargetStatus = "No animated target USDZ exported."
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        decodedFrames = []
        currentVideoFrameImage = nil
        currentFrameIndex = 0
        currentTimeSeconds = 0
        maxFrameIndex = 0
        videoPlaybackStatus = "Decoding frames..."
        status = "Loaded video: \(url.lastPathComponent)"
        log("Opened \(url.lastPathComponent)")

        diagnostics.log("""
        Video state after selection:
          videoURL set: \(videoURL != nil)
          securityScoped: \(didAccess)
          decodedFrames cleared: \(decodedFrames.count)
          rawCapture cleared: \(rawCapture == nil)
          normalized cleared: \(normalizedCapture == nil)
          smoothed cleared: \(smoothedCapture == nil)
        """)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        audioPlayer = player
        installAudioEndObserver(for: item)

        print(
            """
            [RotoMotion Video] Opened video for frame-image playback
              url: \(url.path)
              securityScoped: \(didAccess)
            """
        )

        Task { @MainActor in
            let cache = RotoVideoFrameCache()
            diagnostics.log("Starting SOURCE frame decode for \(url.lastPathComponent).")

            await cache.loadSourceFrames(
                from: url,
                maxFrames: 0,
                maximumImageDimension: 1280
            )

            let frames = cache.frames
            let fpsEstimate = RotoVideoFrameCache.estimatedFPS(frames: frames)

            decodedFrames = frames
            maxFrameIndex = max(0, frames.count - 1)
            currentFrameIndex = 0
            currentTimeSeconds = frames.first?.timeSeconds ?? 0
            currentVideoFrameImage = frames.first?.image
            updateActiveCameraIntrinsicsForCurrentMonocularFrame()
            imageRenderToken += 1
            videoPlaybackStatus = frames.isEmpty
                ? cache.status
                : "Video frames ready: \(frames.count)"
            status = "Video ready: \(frames.count) source frames"

            diagnostics.log("""
            SOURCE frame decode completed and assigned to UI:
              decodedFrames: \(decodedFrames.count)
              estimatedFPS: \(String(format: "%.3f", fpsEstimate))
              maxFrameIndex: \(maxFrameIndex)
              currentFrameIndex: \(currentFrameIndex)
              currentVideoFrameImage exists: \(currentVideoFrameImage != nil)
              imageRenderToken: \(imageRenderToken)
              imageSize: \(String(describing: currentVideoFrameImage?.size))
              Run Vision enabled: \(runVisionDisabledReason == nil)
              Run Vision disabled reason: \(runVisionDisabledReason ?? "none")
            """)

            if !decodedFrames.isEmpty && currentVideoFrameImage == nil {
                diagnostics.log("ERROR: decodedFrames non-empty but currentVideoFrameImage nil.")
            }

            do {
                project = try await RotoMotionProject.load(videoURL: url)
                log("Loaded video metadata.")
            } catch {
                log("Video metadata failed: \(error.localizedDescription)")
            }
        }
    }

    func clearSpatialVideoState(clearURL: Bool = true) {
        if clearURL {
            spatialVideoURL = nil
        }

        leftEyeFrames = []
        rightEyeFrames = []
        spatialLeftEyeFrames = []
        spatialRightEyeFrames = []
        spatialDiagnostics = []
        spatialDumpDirectoryPath = ""
        spatialLeftPreviewImage = nil
        spatialRightPreviewImage = nil
        spatialDecodeStatus = "No spatial video loaded."
        rawLeftVisionCapture = nil
        rawRightVisionCapture = nil
        normalizedLeftCapture = nil
        normalizedRightCapture = nil
        stereoJointCapture = nil
        conditionedStereoJointCapture = nil
        resetSpatialDisparityState(status: "No disparity map built.")
        spatialVideoMetadata = nil
        spatialStereoAvailable = false
        spatialDepthStatus = "No stereo depth available."
        stereoConditioningStatus = "No conditioned stereo targets."
        invalidateStereoToRigAlignment("spatial video state reset")
        spatialVideoStatus = "No spatial video loaded."
        stereoVisionStatus = "No stereo Vision solve yet."
        spatialSolveReadiness = captureMode == .spatialVideo ? .needsVision : .notSpatial
        spatialSolveStatus = captureMode == .spatialVideo
            ? "Spatial video loaded. Run Vision on both eyes, then build disparity before solve."
            : "Monocular mode."
        solveTargetMode = .monocularRayPinned
        applySolvedPoseToReferenceRig = false
        activeCameraProfileSource = .monocularVerticalProfile
        updateActiveCameraIntrinsicsForCurrentMonocularFrame()
    }

    private func resetSpatialDisparityState(status: String) {
        spatialDisparityMapCapture = nil
        spatialDisparityPreviewCapture = nil
        jointDepthEvidenceCapture = nil
        spatialDisparityStatus = status
        spatialRayPinDepthMode = .leftEyeRayPinningFallback
        finishSpatialDisparityProgress(
            progress: 0,
            text: "No disparity build running."
        )
        updateDisparityProgress(
            phase: .idle,
            fraction: 0,
            title: "No disparity build.",
            detail: status,
            currentFrame: 0,
            totalFrames: 0
        )
        resetSpatialDisparityDebugProof(status: "No disparity debug proof.")
        resetFusedStereoTargetState(status: "No fused stereo targets.")
        updateSpatialSolveReadiness()
    }

    private func resetSpatialDisparityDebugProof(status: String) {
        spatialDisparityDebugStatus = status
        spatialDisparityDebugDirectoryPath = ""
        spatialDisparityDepthPreviewImage = nil
        spatialDisparityConfidencePreviewImage = nil
        spatialDisparityRawPreviewImage = nil
    }

    private func resetFusedStereoTargetState(status: String) {
        fusedStereoJointTargetCapture = nil
        fusedStereoTargetStatus = status
    }

    private func startSpatialDisparityProgressPolling(
        _ tracker: SpatialDisparityBuildProgressTracker
    ) {
        spatialDisparityProgressTask?.cancel()
        let startedAt = Date()
        spatialDisparityProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = tracker.snapshot()
                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = snapshot.fraction > 0
                    ? elapsed * (1.0 - snapshot.fraction) / max(snapshot.fraction, 0.0001)
                    : 0

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.spatialDisparityBuildProgress = snapshot.fraction
                    self.spatialDisparityBuildProgressText = snapshot.statusText
                    self.updateDisparityProgress(
                        phase: self.phaseForDisparityProgressStage(snapshot.stage),
                        fraction: snapshot.fraction,
                        title: "Building Disparity Map",
                        detail: snapshot.statusText,
                        currentFrame: min(snapshot.completedUnits, snapshot.totalUnits),
                        totalFrames: snapshot.totalUnits,
                        currentRow: 0,
                        totalRows: 0,
                        elapsedSeconds: elapsed,
                        estimatedRemainingSeconds: remaining,
                        validPercent: self.spatialDisparityLastFrameValidPercent
                    )

                    let shouldLog =
                        Date().timeIntervalSince(self.lastDisparityProgressLogTime) > 0.5 ||
                        snapshot.stage.contains("SUCCESS") ||
                        snapshot.stage.contains("FAILED") ||
                        snapshot.stage.contains("cancel")

                    if shouldLog {
                        self.diagnostics.log(snapshot.statusText)
                        self.lastDisparityProgressLogTime = Date()
                    }
                }

                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func finishSpatialDisparityProgress(
        progress: Double,
        text: String
    ) {
        spatialDisparityProgressTask?.cancel()
        spatialDisparityProgressTask = nil
        stopDisparityUIHeartbeat()
        spatialDisparityBuildProgress = min(1, max(0, progress))
        spatialDisparityBuildProgressText = text
    }

    @MainActor
    func updateDisparityProgress(
        phase: SpatialDisparityBuildPhase,
        fraction: Double,
        title: String,
        detail: String,
        currentFrame: Int,
        totalFrames: Int,
        currentRow: Int = 0,
        totalRows: Int = 0,
        elapsedSeconds: Double = 0,
        estimatedRemainingSeconds: Double = 0,
        validPercent: Double = 0
    ) {
        spatialDisparityBuildPhase = phase
        spatialDisparityProgressFraction = min(1, max(0, fraction))
        spatialDisparityProgressTitle = title
        spatialDisparityProgressDetail = detail
        spatialDisparityCurrentFrame = currentFrame
        spatialDisparityTotalFrames = totalFrames
        spatialDisparityCurrentRow = currentRow
        spatialDisparityTotalRows = totalRows
        spatialDisparityElapsedSeconds = elapsedSeconds
        spatialDisparityEstimatedRemainingSeconds = estimatedRemainingSeconds
        spatialDisparityLastFrameValidPercent = validPercent
        disparityProgressRevision &+= 1
        objectWillChange.send()
    }

    @MainActor
    func startDisparityUIHeartbeat() {
        disparityUIHeartbeatTask?.cancel()

        disparityUIHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)

                await MainActor.run {
                    guard let self,
                          self.isBuildingSpatialDisparity else {
                        return
                    }

                    self.disparityProgressRevision &+= 1
                    self.objectWillChange.send()
                }
            }
        }
    }

    @MainActor
    func stopDisparityUIHeartbeat() {
        disparityUIHeartbeatTask?.cancel()
        disparityUIHeartbeatTask = nil
    }

    @MainActor
    func updateSpatialSolveTrace(_ trace: SpatialSolveTrace) {
        spatialSolveTrace = trace
        lastAutoSpatialDepthZoom = Double(trace.autoDepthFitZoom)
        lastAutoSpatialDepthOffset = Double(trace.autoDepthFitOffset)
        lastSpatialDepthFitScore = Double(trace.depthFitScore)
        lastSpatialDepthFitResidual = Double(trace.depthFitBoneResidualMean)

        spatialSolveProgressTitle = "Spatial Solve: \(trace.phase.rawValue)"
        spatialSolveProgressFraction = trace.phase == .frameAccepted ? 1 : spatialSolveProgressFraction
        spatialSolveProgressDetail = """
        frame: \(trace.frameIndex)
        mode: \(trace.solveTargetMode)
        depth: \(trace.depthMode)
        evidence joints: \(trace.depthEvidenceJoints)
        exact depth targets: \(trace.exactDepthTargets)
        affine calibration: \(trace.depthCalibrationValid) scale \(String(format: "%.4f", trace.affineScale)) offset \(String(format: "%.4f", trace.affineOffset))
        affine anchors/residual: \(trace.affineAnchorCount) / \(String(format: "%.4f", trace.affineMedianResidual))
        depth fit: zoom \(String(format: "%.3f", trace.depthFitZoom)) offset \(String(format: "%.3f", trace.depthFitOffset)) pivot \(String(format: "%.3f", trace.depthFitPivotSceneDepth))
        fit score: \(String(format: "%.5f", trace.depthFitScore)) bone \(String(format: "%.5f", trace.depthFitBoneResidualMean)) target \(String(format: "%.5f", trace.depthFitTargetDistanceMean))
        root: \(trace.displayRootPosition.simdFloat)
        mesh hidden: \(trace.meshHidden)
        projected: \(trace.meshProjectedOnScreen)
        bounds: \(trace.projectedBounds)
        avg ray: \(String(format: "%.5f", trace.avgRayDistance))
        worst: \(trace.worstJoint) \(String(format: "%.5f", trace.worstRayDistance))
        rejected: \(trace.rejectionReason)
        """
    }

    @MainActor
    func requestViewportRefresh(reason: String) {
        viewportRefreshRevision &+= 1
        lastViewportRefreshReason = reason
        objectWillChange.send()
    }

    private func visibilityToggleChanged(
        name: String,
        value: Bool
    ) {
        visibilityControlChanged(name: "\(name)=\(value)")
    }

    private func visibilityControlChanged(name: String) {
        guard !suppressSessionDirtyTracking else {
            return
        }

        visibilityToggleRevision &+= 1
        requestViewportRefresh(reason: "visibility changed \(name)")
    }

    @MainActor
    func invalidateBakeAndRefresh(reason: String) {
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Bake is stale. Re-bake rig animation for export."
        sessionIsDirty = true
        solveInputRevision &+= 1
        requestViewportRefresh(reason: reason)
    }

    func spatialDepthControlsChanged() {
        spatialDepthControlRevision &+= 1
        invalidateBakeAndRefresh(reason: "spatial depth controls changed")
        diagnostics.log("""
        Spatial depth controls changed:
          manualDepthZoom: \(manualSpatialDepthZoom)
          manualDepthOffset: \(manualSpatialDepthOffset)
          autoDepthFit: \(autoSpatialDepthFitEnabled)
          spatialDepthControlRevision: \(spatialDepthControlRevision)
          viewportRefreshRevision: \(viewportRefreshRevision)
        """)
        applyCurrentFrameToLiveRig()
    }

    @MainActor
    func setManualSpatialDepthZoom(_ value: Double) {
        let clamped = max(0.35, min(2.0, value))

        guard abs(manualSpatialDepthZoom - clamped) > 0.000001 else {
            return
        }

        manualSpatialDepthZoom = clamped
        spatialDepthControlRevision &+= 1

        invalidateBakeAndRefresh(
            reason: "manual spatial depth zoom changed to \(String(format: "%.4f", clamped))"
        )
        diagnostics.log("""
        Spatial depth controls changed:
          manualDepthZoom: \(manualSpatialDepthZoom)
          manualDepthOffset: \(manualSpatialDepthOffset)
          autoDepthFit: \(autoSpatialDepthFitEnabled)
          spatialDepthControlRevision: \(spatialDepthControlRevision)
          viewportRefreshRevision: \(viewportRefreshRevision)
        """)
        applyCurrentFrameToLiveRig()
    }

    @MainActor
    func setManualSpatialDepthOffset(_ value: Double) {
        let clamped = max(-8.0, min(8.0, value))

        guard abs(manualSpatialDepthOffset - clamped) > 0.000001 else {
            return
        }

        manualSpatialDepthOffset = clamped
        spatialDepthControlRevision &+= 1

        invalidateBakeAndRefresh(
            reason: "manual spatial depth offset changed to \(String(format: "%.4f", clamped))"
        )
        diagnostics.log("""
        Spatial depth controls changed:
          manualDepthZoom: \(manualSpatialDepthZoom)
          manualDepthOffset: \(manualSpatialDepthOffset)
          autoDepthFit: \(autoSpatialDepthFitEnabled)
          spatialDepthControlRevision: \(spatialDepthControlRevision)
          viewportRefreshRevision: \(viewportRefreshRevision)
        """)
        applyCurrentFrameToLiveRig()
    }

    @MainActor
    func setAutoSpatialDepthFitEnabled(_ value: Bool) {
        guard autoSpatialDepthFitEnabled != value else {
            return
        }

        autoSpatialDepthFitEnabled = value
        spatialDepthControlRevision &+= 1

        invalidateBakeAndRefresh(
            reason: "auto spatial depth fit changed to \(value)"
        )
        diagnostics.log("""
        Spatial depth controls changed:
          manualDepthZoom: \(manualSpatialDepthZoom)
          manualDepthOffset: \(manualSpatialDepthOffset)
          autoDepthFit: \(autoSpatialDepthFitEnabled)
          spatialDepthControlRevision: \(spatialDepthControlRevision)
          viewportRefreshRevision: \(viewportRefreshRevision)
        """)
        applyCurrentFrameToLiveRig()
    }

    @MainActor
    func resetSpatialDepthPanZoom() {
        manualSpatialDepthZoom = 1.0
        manualSpatialDepthOffset = 0.0
        spatialDepthControlRevision &+= 1
        spatialSolveStatus = "Spatial depth pan/zoom reset."
        invalidateBakeAndRefresh(reason: "spatial depth pan/zoom reset")
        diagnostics.log("""
        Spatial depth controls changed:
          manualDepthZoom: \(manualSpatialDepthZoom)
          manualDepthOffset: \(manualSpatialDepthOffset)
          autoDepthFit: \(autoSpatialDepthFitEnabled)
          spatialDepthControlRevision: \(spatialDepthControlRevision)
          viewportRefreshRevision: \(viewportRefreshRevision)
        """)
        applyCurrentFrameToLiveRig()
    }

    @MainActor
    func nudgeSpatialDepthOffset(_ delta: Double) {
        setManualSpatialDepthOffset(manualSpatialDepthOffset + delta)
    }

    @MainActor
    func nudgeSpatialDepthZoom(_ delta: Double) {
        setManualSpatialDepthZoom(manualSpatialDepthZoom + delta)
    }

    private func phaseForDisparityProgressStage(
        _ stage: String
    ) -> SpatialDisparityBuildPhase {
        if stage.contains("Preparing") {
            return .preparing
        }

        if stage.contains("Computing") || stage.contains("Computed") {
            return .computingFrame
        }

        if stage.contains("Writing") || stage.contains("Wrote") {
            return .writingPreviews
        }

        return .preparing
    }

    func loadSpatialVideo(
        url: URL
    ) async {
        stopFramePlayback()
        releaseCurrentVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()

        videoSecurityScopedURL = url
        videoSecurityScopedAccessActive = didAccess
        captureMode = .spatialVideo
        spatialVideoURL = url
        videoURL = url
        lastLoadedVideoURL = url
        outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)

        clearSpatialVideoState(clearURL: false)

        decodedFrames = []
        currentVideoFrameImage = nil
        currentFrameIndex = 0
        currentTimeSeconds = 0
        maxFrameIndex = 0
        rawCapture = nil
        normalizedCapture = nil
        smoothedCapture = nil
        fitResult = nil
        currentRaySolveResult = nil
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        resetRotationAuthoringForNewSession()
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Spatial video changed. Bake rig animation before export."
        sessionPoseSource = .none
        sessionPoseStatus = "No session pose source detected."
        currentVideoPlaneSize = nil
        raySolveStatus = "Ray solve not run."
        rayAnimationSolveStatus = "Ray animation solve not run."
        raySolvedUSDZExportStatus = "No ray solve USDZ exported."
        usdzRetargetStatus = "No animated target USDZ exported."
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        spatialVideoStatus = "Decoding spatial video..."
        status = spatialVideoStatus

        diagnostics.log("""
        Open Spatial Video selected:
          path: \(url.path)
          securityScoped: \(didAccess)
          baselineMeters: \(spatialBaselineMeters)
          horizontalFOVDegrees: \(spatialHorizontalFOVDegrees)
          verticalFOVDegrees: \(spatialVerticalFOVDegrees)
        """)

        do {
            let decoded = try await SpatialVideoFrameDecoder.decodeLeftRightFrames(
                url: url
            )

            leftEyeFrames = decoded.leftFrames
            rightEyeFrames = decoded.rightFrames
            spatialLeftEyeFrames = decoded.stereoDiagnostics.leftFrames
            spatialRightEyeFrames = decoded.stereoDiagnostics.rightFrames
            spatialDiagnostics = decoded.stereoDiagnostics.diagnostics
            spatialDumpDirectoryPath = decoded.stereoDiagnostics.dumpDirectory.path
            spatialLeftPreviewImage = decoded.stereoDiagnostics.leftFrames.first.map {
                NSImage(
                    cgImage: $0.cgImage,
                    size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height)
                )
            }
            spatialRightPreviewImage = decoded.stereoDiagnostics.rightFrames.first.map {
                NSImage(
                    cgImage: $0.cgImage,
                    size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height)
                )
            }
            spatialVideoMetadata = decoded.metadata
            updateActiveCameraIntrinsicsForSpatialVideo()
            spatialStereoAvailable = !decoded.leftFrames.isEmpty && !decoded.rightFrames.isEmpty
            spatialDepthStatus = spatialStereoAvailable
                ? "Stereo left/right frames are available. Run Vision to build stereo depth."
                : "Stereo depth unavailable: decoded spatial video did not provide both eyes."
            decodedFrames = cachedFrames(from: decoded.leftFrames)
            maxFrameIndex = max(0, decodedFrames.count - 1)
            currentFrameIndex = 0
            currentTimeSeconds = decodedFrames.first?.timeSeconds ?? 0
            currentVideoFrameImage = decodedFrames.first?.image
            imageRenderToken += 1

            spatialVideoStatus = """
            Spatial video loaded.
            Displaying left eye on video card.
              left frames: \(decoded.leftFrames.count)
              right frames: \(decoded.rightFrames.count)
              fps: \(String(format: "%.3f", decoded.fps))
              baseline: \(decoded.metadata.baselineMeters.map { String(format: "%.5f", $0) } ?? "manual \(String(format: "%.5f", spatialBaselineMeters))")
              hFOV: \(decoded.metadata.horizontalFOVDegrees.map { String(format: "%.2f", $0) } ?? "manual \(String(format: "%.2f", spatialHorizontalFOVDegrees))")
            """
            spatialDecodeStatus = """
            Spatial stereo decode succeeded.
            Left frames: \(decoded.stereoDiagnostics.leftFrames.count)
            Right frames: \(decoded.stereoDiagnostics.rightFrames.count)
            Dump dir: \(decoded.stereoDiagnostics.dumpDirectory.path)
            """
            videoPlaybackStatus = "Spatial left-eye frames ready: \(decoded.leftFrames.count)"
            status = "Spatial video ready: \(decoded.leftFrames.count) stereo frames"

            diagnostics.log("""
            Spatial display assigned to active video card:
              using: left eye
              frames: \(decodedFrames.count)
              estimatedFPS: \(String(format: "%.3f", RotoVideoFrameCache.estimatedFPS(frames: decodedFrames)))
              currentImage: \(currentVideoFrameImage != nil)

            Spatial video metadata:
              baselineMeters: \(decoded.metadata.baselineMeters.map { "\($0)" } ?? "nil")
              horizontalFOVDegrees: \(decoded.metadata.horizontalFOVDegrees.map { "\($0)" } ?? "nil")
              verticalFOVDegrees: \(String(format: "%.3f", activeCameraIntrinsics.verticalFOVDegrees))
              disparityAdjustment: \(decoded.metadata.disparityAdjustment.map { "\($0)" } ?? "nil")
              imageSize: \(decoded.metadata.imageWidth)x\(decoded.metadata.imageHeight)
              manualOverride: \(useManualSpatialCameraOverrides)

            Spatial stereo diagnostic dump:
              dumpDirectory: \(decoded.stereoDiagnostics.dumpDirectory.path)
              leftPreview: \(spatialLeftPreviewImage != nil)
              rightPreview: \(spatialRightPreviewImage != nil)
              diagnostics: \(spatialDiagnostics.count)
            """)
            diagnostics.log("""
            Viewport camera FOV:
              captureMode: \(captureMode.rawValue)
              source: \(activeCameraIntrinsics.source)
              horizontalFOV: \(activeCameraIntrinsics.horizontalFOVDegrees)
              verticalFOV: \(activeCameraIntrinsics.verticalFOVDegrees)
            """)
            applySolvedPoseToReferenceRig = false
            updateSpatialSolveReadiness()
        } catch {
            leftEyeFrames = []
            rightEyeFrames = []
            spatialLeftEyeFrames = []
            spatialRightEyeFrames = []
            spatialDiagnostics = []
            spatialDumpDirectoryPath = ""
            spatialLeftPreviewImage = nil
            spatialRightPreviewImage = nil
            spatialDecodeStatus = "Spatial stereo decode FAILED: \(error.localizedDescription)"
            rawLeftVisionCapture = nil
            rawRightVisionCapture = nil
            normalizedLeftCapture = nil
            normalizedRightCapture = nil
            stereoJointCapture = nil
            conditionedStereoJointCapture = nil
            stereoConditioningStatus = "No conditioned stereo targets."
            invalidateStereoToRigAlignment("spatial decode failed")
            resetSpatialDisparityState(status: "Spatial disparity unavailable: spatial decode failed.")
            spatialVideoMetadata = try? await SpatialVideoMetadataReader.readMetadata(url: url)
            spatialStereoAvailable = false
            spatialDepthStatus = "Spatial stereo decode failed. Fix left/right MV-HEVC decode before Vision."
            decodedFrames = []
            maxFrameIndex = 0
            currentFrameIndex = 0
            currentTimeSeconds = 0
            currentVideoFrameImage = nil
            imageRenderToken += 1
            spatialVideoStatus = "Spatial video decode failed: \(error.localizedDescription)"
            videoPlaybackStatus = "Spatial video decode failed. No fallback display."
            status = spatialVideoStatus
            applySolvedPoseToReferenceRig = false
            updateSpatialSolveReadiness()
            diagnostics.log("""
            Spatial video decode FAILED:
              no fallback: true
              active UI assignment: skipped
              error: \(error)
              path: \(url.path)
            """)
        }
    }

    func runVisionOnSpatialVideo() async {
        guard let spatialVideoURL else {
            stereoVisionStatus = "Spatial Vision failed: open a spatial video first."
            spatialVideoStatus = stereoVisionStatus
            status = stereoVisionStatus
            diagnostics.log(stereoVisionStatus)
            return
        }

        guard captureMode == .spatialVideo else {
            diagnostics.log("runVisionOnSpatialVideo called outside spatial mode.")
            return
        }

        guard !leftEyeFrames.isEmpty else {
            stereoVisionStatus = "Spatial Vision failed: left-eye frames are empty. Fix spatial decode first."
            spatialVideoStatus = stereoVisionStatus
            status = stereoVisionStatus
            diagnostics.log(stereoVisionStatus)
            return
        }

        guard !rightEyeFrames.isEmpty else {
            stereoVisionStatus = "Spatial Vision failed: right-eye frames are empty. Fix spatial decode first."
            spatialVideoStatus = stereoVisionStatus
            status = stereoVisionStatus
            diagnostics.log(stereoVisionStatus)
            return
        }

        isWorking = true
        stereoVisionStatus = "Running strict Spatial Vision on left and right eyes..."
        spatialVideoStatus = stereoVisionStatus
        status = stereoVisionStatus
        lastVisionError = nil
        resetSpatialDisparityState(status: "Spatial Vision changed. Rebuild disparity map.")

        diagnostics.log("""
        Running strict Spatial Vision:
          leftFrames: \(leftEyeFrames.count)
          rightFrames: \(rightEyeFrames.count)
          no fallback: true
        """)

        do {
            let fps = RotoVideoFrameCache.estimatedFPS(frames: cachedFrames(from: leftEyeFrames))
            let left = try await exporter.runExtraction(
                frames: leftEyeFrames,
                sourceURL: spatialVideoURL,
                eyeLabel: "left",
                nominalFPS: fps > 0 ? fps : visionSampleFPS
            )
            let right = try await exporter.runExtraction(
                frames: rightEyeFrames,
                sourceURL: spatialVideoURL,
                eyeLabel: "right",
                nominalFPS: fps > 0 ? fps : visionSampleFPS
            )

            rawLeftVisionCapture = left
            rawRightVisionCapture = right
            normalizedLeftCapture = PoseNormalizer.normalize(rawCapture: left)
            normalizedRightCapture = PoseNormalizer.normalize(rawCapture: right)

            // Keep the left eye as the existing monocular viewport/overlay source.
            rawCapture = left
            normalizedCapture = normalizedLeftCapture
            smoothedCapture = nil
            currentRaySolveResult = nil
            rayAnimationSolveResult = nil
            sessionArmatureSnapshot = nil
            sessionArmaturePoseBuffer = nil
            bakedRigAnimation = nil
            bakedRigAnimationStatus = "Spatial Vision changed. Bake rig animation before export."
            maxFrameIndex = max(maxFrameIndex, max(0, left.frames.count - 1))

            guard spatialVideoMetadata != nil else {
                isWorking = false
                stereoJointCapture = nil
                conditionedStereoJointCapture = nil
                stereoConditioningStatus = "No conditioned stereo targets."
                invalidateStereoToRigAlignment("spatial metadata missing")
                resetSpatialDisparityState(status: "Spatial disparity unavailable: missing spatial metadata.")
                spatialStereoAvailable = false
                stereoVisionStatus = "Spatial Vision failed: missing spatial video metadata."
                spatialVideoStatus = stereoVisionStatus
                status = stereoVisionStatus
                diagnostics.log(stereoVisionStatus)
                return
            }

            try buildStereoJointDepth()
            spatialStereoAvailable = stereoJointCapture != nil
            showStereo3DSkeleton = true

            stereoVisionStatus = """
            Spatial Vision success:
              left raw frames: \(left.frames.count)
              right raw frames: \(right.frames.count)
              left normalized: \(normalizedLeftCapture?.frames.count ?? 0)
              right normalized: \(normalizedRightCapture?.frames.count ?? 0)
              stereo frames: \(stereoJointCapture?.frames.count ?? 0)
            """
            spatialVideoStatus = stereoVisionStatus
            isWorking = false
            status = stereoVisionStatus
            applySolvedPoseToReferenceRig = false
            updateSpatialSolveReadiness()
            diagnostics.log(stereoVisionStatus)
            diagnostics.log("""
            Spatial both-eye Vision overlay state:
              leftRawFrames: \(rawLeftVisionCapture?.frames.count ?? 0)
              rightRawFrames: \(rawRightVisionCapture?.frames.count ?? 0)
              leftNormalizedFrames: \(normalizedLeftCapture?.frames.count ?? 0)
              rightNormalizedFrames: \(normalizedRightCapture?.frames.count ?? 0)
              rightRawOverlayDefaultVisible: \(shouldShowRightEyeVisionOverlay)
              rightNormalizedOverlayDefaultVisible: \(shouldShowRightEyeNormalizedOverlay)
            """)
        } catch {
            isWorking = false
            stereoJointCapture = nil
            conditionedStereoJointCapture = nil
            stereoConditioningStatus = "No conditioned stereo targets."
            invalidateStereoToRigAlignment("spatial Vision failed")
            resetSpatialDisparityState(status: "Spatial disparity unavailable: spatial Vision failed.")
            spatialStereoAvailable = false
            stereoVisionStatus = "Spatial Vision failed: \(error.localizedDescription)"
            spatialVideoStatus = stereoVisionStatus
            status = stereoVisionStatus
            lastVisionError = error.localizedDescription
            applySolvedPoseToReferenceRig = false
            updateSpatialSolveReadiness()
            diagnostics.log("""
            Spatial Vision FAILED:
              error: \(error)
            """)
        }
    }

    @discardableResult
    func buildStereoJointDepth() throws -> StereoMeshyJointCapture {
        guard let left = normalizedLeftCapture,
              let right = normalizedRightCapture else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7501,
                userInfo: [NSLocalizedDescriptionKey: "Normalize both spatial eyes before stereo triangulation."]
            )
        }

        let metadata = effectiveSpatialMetadata()
        diagnostics.log("""
        Stereo triangulation coordinate convention:
          normalizedY: \(stereoYConvention.rawValue)

        Stereo triangulation parameters:
          baselineMeters: \(metadata.baselineMeters.map { "\($0)" } ?? "nil")
          horizontalFOVDegrees: \(metadata.horizontalFOVDegrees.map { "\($0)" } ?? "nil")
          imageWidth: \(metadata.imageWidth)
          imageHeight: \(metadata.imageHeight)
          source: \(useManualSpatialCameraOverrides ? "manual overrides + decodedPixelBufferSize" : "formatDescription + decodedPixelBufferSize")
          manualSpatialCameraOverrides: \(useManualSpatialCameraOverrides)
        """)

        let stereo = try StereoJointTriangulator.triangulate(
            left: left,
            right: right,
            metadata: metadata,
            settings: StereoTriangulationSettings(
                yConvention: stereoYConvention
            )
        )

        stereoJointCapture = stereo
        let conditioned = StereoTargetConditioner.condition(
            stereo: stereo,
            settings: stereoConditioningSettings
        )
        conditionedStereoJointCapture = conditioned
        invalidateStereoToRigAlignment("conditioned stereo targets rebuilt")
        calibrateStereoToRigAlignmentIfPossible()
        resetSpatialDisparityState(status: "Stereo joint depth changed. Rebuild disparity map.")

        let firstConditionedCount = conditioned.frames.first?.joints.count ?? 0
        stereoConditioningStatus = """
        Conditioned stereo targets built:
          frames: \(conditioned.frames.count)
          first frame joints: \(firstConditionedCount)
          smoothingAlpha: \(stereoConditioningSettings.smoothingAlpha)
          maxFrameJumpMeters: \(stereoConditioningSettings.maxFrameJumpMeters)
        """
        diagnostics.log(stereoConditioningStatus)

        buildFusedStereoTargets()

        let validCounts = stereo.frames.map {
            $0.joints.values.filter(\.validStereo).count
        }
        let averageValid = validCounts.isEmpty
            ? 0
            : Double(validCounts.reduce(0, +)) / Double(validCounts.count)

        spatialStereoAvailable = true
        applySolvedPoseToReferenceRig = false
        updateSpatialSolveReadiness()
        spatialDepthStatus = """
        Stereo joint depth built:
          frames: \(stereo.frames.count)
          avg valid joints/frame: \(String(format: "%.1f", averageValid))
          baselineMeters: \(String(format: "%.5f", metadata.baselineMeters ?? 0))
          hFOV: \(String(format: "%.2f", metadata.horizontalFOVDegrees ?? 0))
          conditionedFrames: \(conditioned.frames.count)
          solveTargetMode: \(solveTargetMode.rawValue)
        """
        spatialVideoStatus = spatialDepthStatus
        stereoVisionStatus = spatialVideoStatus
        status = spatialVideoStatus
        diagnostics.log(spatialVideoStatus)

        if let first = stereo.frames.first {
            let valid = first.joints.values.filter(\.validStereo).count
            let invalid = first.joints.values.filter { !$0.validStereo }.count
            let validJoints = first.joints.values.filter(\.validStereo)
            let avgLeftError = validJoints.isEmpty
                ? 0
                : validJoints.map(\.reprojectionErrorLeft).reduce(0, +) / Double(validJoints.count)
            let avgRightError = validJoints.isEmpty
                ? 0
                : validJoints.map(\.reprojectionErrorRight).reduce(0, +) / Double(validJoints.count)
            let samples = first.joints
                .sorted { $0.key < $1.key }
                .prefix(8)
                .map {
                    "\($0.key): valid=\($0.value.validStereo) depth=\(String(format: "%.3f", $0.value.depthMeters)) reason=\($0.value.rejectReason ?? "none")"
                }
                .joined(separator: "\n")

            diagnostics.log("""
            Stereo triangulation first frame:
              valid joints: \(valid)
              invalid joints: \(invalid)
              sample depths:
            \(samples)
            """)

            let proofSamples = ["Head", "Hips", "LeftShoulder", "RightShoulder"]
                .compactMap { name -> String? in
                    guard let joint = first.joints[name],
                          joint.validStereo else {
                        return nil
                    }

                    return "\(name) left original=(\(String(format: "%.4f", joint.leftX)),\(String(format: "%.4f", joint.leftY))) reproj=(\(String(format: "%.4f", joint.reprojectedLeftX)),\(String(format: "%.4f", joint.reprojectedLeftY))) err=\(String(format: "%.5f", joint.reprojectionErrorLeft))"
                }
                .joined(separator: "\n")

            diagnostics.log("""
            Stereo reprojection proof:
              frame: \(first.frameIndex)
              yConvention: \(stereoYConvention.rawValue)
              avgLeftError: \(String(format: "%.6f", avgLeftError))
              avgRightError: \(String(format: "%.6f", avgRightError))
              sample:
            \(proofSamples.isEmpty ? "none" : proofSamples)
            """)
        }

        return stereo
    }

    func rebuildStereoJointDepthFromCurrentSettings() {
        do {
            _ = try buildStereoJointDepth()
        } catch {
            spatialStereoAvailable = false
            stereoJointCapture = nil
            conditionedStereoJointCapture = nil
            stereoConditioningStatus = "No conditioned stereo targets."
            invalidateStereoToRigAlignment("stereo joint depth failed")
            resetSpatialDisparityState(status: "Stereo joint depth failed. Rebuild disparity after stereo depth succeeds.")
            spatialVideoStatus = "Stereo depth failed: \(error.localizedDescription)"
            spatialDepthStatus = spatialVideoStatus
            stereoVisionStatus = spatialVideoStatus
            status = spatialVideoStatus
            diagnostics.log(spatialVideoStatus)
        }
    }

    func buildSpatialDisparityDebugFrame() async {
        guard !isBuildingSpatialDisparity else {
            diagnostics.log("Disparity debug build ignored: already building.")
            return
        }

        guard captureMode == .spatialVideo else {
            spatialDisparityDebugStatus = "Disparity debug requires spatial video."
            status = spatialDisparityDebugStatus
            diagnostics.log(spatialDisparityDebugStatus)
            updateSpatialSolveReadiness()
            return
        }

        guard !spatialLeftEyeFrames.isEmpty,
              !spatialRightEyeFrames.isEmpty else {
            spatialDisparityDebugStatus = "Disparity debug failed: missing decoded left/right eye frames."
            status = spatialDisparityDebugStatus
            diagnostics.log(spatialDisparityDebugStatus)
            updateSpatialSolveReadiness()
            return
        }

        guard spatialVideoMetadata != nil else {
            spatialDisparityDebugStatus = "Disparity debug failed: missing spatial metadata."
            status = spatialDisparityDebugStatus
            diagnostics.log(spatialDisparityDebugStatus)
            updateSpatialSolveReadiness()
            return
        }

        let frameCount = min(spatialLeftEyeFrames.count, spatialRightEyeFrames.count)
        let frameIndex = min(max(spatialDisparityDebugFrameIndex, 0), frameCount - 1)
        let left = spatialLeftEyeFrames[frameIndex]
        let right = spatialRightEyeFrames[frameIndex]
        let metadata = effectiveSpatialMetadata()
        let settings = stereoDisparitySettings

        isWorking = true
        isBuildingSpatialDisparity = true
        resetSpatialDisparityDebugProof(status: "Building one-frame disparity debug...")
        spatialDisparityBuildProgress = 0
        spatialDisparityBuildProgressText = "Building one-frame disparity debug..."
        status = spatialDisparityDebugStatus

        diagnostics.log("""
        Building ONE-FRAME disparity debug:
          frameIndex: \(frameIndex)
          leftFrames: \(spatialLeftEyeFrames.count)
          rightFrames: \(spatialRightEyeFrames.count)
          scale: \(settings.scale)
          patchRadius: \(settings.patchRadius)
          searchRadius: \(settings.searchRadius)
          searchStep: \(settings.searchStep)
          baselineMeters: \(metadata.baselineMeters ?? -1)
          horizontalFOVDegrees: \(metadata.horizontalFOVDegrees ?? -1)
        """)

        defer {
            isBuildingSpatialDisparity = false
            isWorking = false
            updateSpatialSolveReadiness()
        }

        do {
            let disparityFrame = try await Task.detached(priority: .userInitiated) {
                let leftLuminance = try StereoLuminanceConverter.makeLuminanceBuffer(
                    from: left.cgImage,
                    scale: settings.scale
                )

                let rightLuminance = try StereoLuminanceConverter.makeLuminanceBuffer(
                    from: right.cgImage,
                    scale: settings.scale
                )

                return try StereoDisparityComputer.computeFrame(
                    frameIndex: left.frameIndex,
                    timeSeconds: CMTimeGetSeconds(left.presentationTime),
                    left: leftLuminance,
                    right: rightLuminance,
                    metadata: metadata,
                    settings: settings
                )
            }.value

            let debug = try SpatialDisparityDebugDumper.dumpDebugImages(
                frame: disparityFrame
            )
            let stats = SpatialDisparityDebugStats.make(frame: disparityFrame)

            spatialDisparityDepthPreviewImage = debug.depthImage
            spatialDisparityConfidencePreviewImage = debug.confidenceImage
            spatialDisparityRawPreviewImage = debug.rawDisparityImage
            spatialDisparityDebugDirectoryPath = debug.directory.path

            spatialDisparityDebugStatus = """
            ONE-FRAME disparity debug SUCCESS:
              frame: \(disparityFrame.frameIndex)
              mapSize: \(disparityFrame.width)x\(disparityFrame.height)
              validDepthPixels: \(stats.validDepthPixels)
              totalPixels: \(stats.totalPixels)
              validPercent: \(String(format: "%.2f", stats.validPercent))%
              minDepth: \(String(format: "%.3f", stats.minDepthMeters))
              medianDepth: \(String(format: "%.3f", stats.medianDepthMeters))
              maxDepth: \(String(format: "%.3f", stats.maxDepthMeters))
              dumpDir: \(debug.directory.path)
            """
            status = spatialDisparityDebugStatus
            diagnostics.log(spatialDisparityDebugStatus)
            finishSpatialDisparityProgress(
                progress: 1,
                text: "One-frame disparity debug complete."
            )
        } catch {
            resetSpatialDisparityDebugProof(
                status: "ONE-FRAME disparity debug FAILED: \(error.localizedDescription)"
            )
            status = spatialDisparityDebugStatus
            diagnostics.log(spatialDisparityDebugStatus)
            finishSpatialDisparityProgress(
                progress: 0,
                text: "One-frame disparity debug failed."
            )
        }
    }

    @discardableResult
    func buildSpatialDisparityMaps() async -> Bool {
        guard !isBuildingSpatialDisparity else {
            diagnostics.log("Disparity build ignored: already building.")
            return false
        }

        guard captureMode == .spatialVideo else {
            spatialDisparityStatus = "Disparity build requires spatial video."
            status = spatialDisparityStatus
            diagnostics.log(spatialDisparityStatus)
            updateSpatialSolveReadiness()
            return false
        }

        guard !spatialLeftEyeFrames.isEmpty,
              !spatialRightEyeFrames.isEmpty else {
            spatialDisparityStatus = "Disparity build failed: missing decoded left/right eye frames."
            status = spatialDisparityStatus
            diagnostics.log(spatialDisparityStatus)
            updateSpatialSolveReadiness()
            return false
        }

        guard spatialVideoMetadata != nil else {
            spatialDisparityStatus = "Disparity build failed: missing spatial metadata."
            status = spatialDisparityStatus
            diagnostics.log(spatialDisparityStatus)
            updateSpatialSolveReadiness()
            return false
        }

        let leftFrames = spatialLeftEyeFrames
        let rightFrames = spatialRightEyeFrames
        let metadata = effectiveSpatialMetadata()
        let settings = stereoDisparitySettings
        let disparityFrameCount = max(min(leftFrames.count, rightFrames.count), 1)
        let search = max(1, settings.searchRadius)
        let step = max(1, settings.searchStep)
        let searchStepCount = Array(stride(from: -search, through: search, by: step)).count + 1
        let disparityProgressUnits = max(disparityFrameCount * searchStepCount, 1)
        let totalProgressUnits = max(disparityProgressUnits + disparityFrameCount, 1)
        let progressTracker = SpatialDisparityBuildProgressTracker()

        isWorking = true
        isBuildingSpatialDisparity = true
        spatialDisparityMapCapture = nil
        spatialDisparityPreviewCapture = nil
        jointDepthEvidenceCapture = nil
        spatialRayPinDepthMode = .leftEyeRayPinningFallback
        resetFusedStereoTargetState(status: "Fused target build unavailable: disparity rebuild in progress.")
        resetSpatialDisparityDebugProof(status: "Building full disparity proof...")
        spatialDisparityStatus = "Building spatial disparity maps..."
        status = spatialDisparityStatus
        spatialDisparityBuildProgress = 0
        spatialDisparityBuildProgressText = "Preparing disparity maps: 0/\(totalProgressUnits)"
        updateDisparityProgress(
            phase: .preparing,
            fraction: 0,
            title: "Building Disparity Map",
            detail: "Preparing disparity maps: 0/\(totalProgressUnits)",
            currentFrame: 0,
            totalFrames: totalProgressUnits
        )
        progressTracker.update(
            stage: "Preparing disparity maps",
            completedUnits: 0,
            totalUnits: totalProgressUnits
        )
        startDisparityUIHeartbeat()
        startSpatialDisparityProgressPolling(progressTracker)
        updateSpatialSolveReadiness()

        diagnostics.log("""
        Building spatial disparity maps:
          leftFrames: \(leftFrames.count)
          rightFrames: \(rightFrames.count)
          scale: \(settings.scale)
          patchRadius: \(settings.patchRadius)
          searchRadius: \(settings.searchRadius)
          searchStep: \(settings.searchStep)
          baselineMeters: \(metadata.baselineMeters.map { "\($0)" } ?? "nil")
          horizontalFOVDegrees: \(metadata.horizontalFOVDegrees.map { "\($0)" } ?? "nil")
        """)

        do {
            let buildResult = try await Task.detached(priority: .userInitiated) {
                let runningOnMainThread = pthread_main_np() != 0
                assert(!runningOnMainThread, "Disparity build must not run on the main thread.")
                print("[DisparityBuild] runningOnMainThread: \(runningOnMainThread)")

                let disparity = try SpatialDisparityMapBuilder.build(
                    leftFrames: leftFrames,
                    rightFrames: rightFrames,
                    metadata: metadata,
                    settings: settings,
                    progress: { stage, completedUnits, _ in
                        progressTracker.update(
                            stage: stage,
                            completedUnits: completedUnits,
                            totalUnits: totalProgressUnits
                        )
                    }
                )

                let preview = try SpatialDisparityPreviewBuilder.buildPreviewCapture(
                    disparity: disparity,
                    progress: { stage, completedFrames, _ in
                        progressTracker.update(
                            stage: stage,
                            completedUnits: disparityProgressUnits + completedFrames,
                            totalUnits: totalProgressUnits
                        )
                    }
                )

                return (disparity, preview)
            }.value
            let disparity = buildResult.0
            let previewResult = buildResult.1

            spatialDisparityMapCapture = disparity
            spatialDisparityPreviewCapture = previewResult.previewCapture

            guard let leftNorm = normalizedLeftCapture else {
                throw NSError(
                    domain: "RotoMotionSpatial",
                    code: 9401,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Disparity map built, but normalizedLeftCapture is missing."
                    ]
                )
            }

            updateDisparityProgress(
                phase: .buildingJointEvidence,
                fraction: 0.98,
                title: "Building Disparity Map",
                detail: "Building joint depth evidence...",
                currentFrame: disparity.frames.count,
                totalFrames: disparity.frames.count
            )

            let evidence = JointDepthEvidenceBuilder.buildCandidateBased(
                disparity: disparity,
                normalizedLeft: leftNorm,
                normalizedRight: normalizedRightCapture,
                stereo: stereoJointCapture,
                conditioned: conditionedStereoJointCapture,
                fused: fusedStereoJointTargetCapture,
                metadata: metadata,
                settings: settings
            )

            jointDepthEvidenceCapture = evidence
            sessionArmaturePoseBuffer = nil
            invalidateBakeAndRefresh(reason: "spatial disparity build success")

            guard let first = disparity.frames.first else {
                throw NSError(
                    domain: "RotoMotionSpatial",
                    code: 9402,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Disparity build produced no frames."
                    ]
                )
            }

            let firstPreview = previewResult.previewCapture.frames.first
            let debug = try SpatialDisparityDebugDumper.dumpDebugImages(frame: first)
            let stats = SpatialDisparityDebugStats.make(frame: first)
            let firstValidPercent = stats.validPercent

            spatialDisparityDepthPreviewImage = debug.depthImage
            spatialDisparityConfidencePreviewImage = debug.confidenceImage
            spatialDisparityRawPreviewImage = debug.rawDisparityImage
            spatialDisparityDebugDirectoryPath = previewResult.dumpDirectory.path
            spatialDisparityLastFrameValidPercent = firstValidPercent

            spatialDisparityDebugStatus = """
            Full disparity first-frame proof SUCCESS:
              frame: \(first.frameIndex)
              mapSize: \(first.width)x\(first.height)
              validDepthPixels: \(stats.validDepthPixels)
              totalPixels: \(stats.totalPixels)
              validPercent: \(String(format: "%.2f", stats.validPercent))%
              minDepth: \(String(format: "%.3f", stats.minDepthMeters))
              medianDepth: \(String(format: "%.3f", stats.medianDepthMeters))
              maxDepth: \(String(format: "%.3f", stats.maxDepthMeters))
              dumpDir: \(previewResult.dumpDirectory.path)
            """
            diagnostics.log(spatialDisparityDebugStatus)
            diagnostics.log("""
            Full disparity first-frame proof:
              frame: \(first.frameIndex)
              mapSize: \(first.width)x\(first.height)
              validDepthPixels: \(stats.validDepthPixels)
              validPercent: \(String(format: "%.2f", stats.validPercent))%
              minDepth: \(String(format: "%.3f", stats.minDepthMeters))
              medianDepth: \(String(format: "%.3f", stats.medianDepthMeters))
              maxDepth: \(String(format: "%.3f", stats.maxDepthMeters))
              dumpDir: \(previewResult.dumpDirectory.path)
            """)

            spatialDisparityStatus = """
            Spatial disparity build SUCCESS:
              frames: \(disparity.frames.count)
              firstMap: \(first.width)x\(first.height)
              previewFrames: \(previewResult.previewCapture.frames.count)
              firstValidDepthPixels: \(firstPreview?.validDepthPixels ?? stats.validDepthPixels)
              jointDepthEvidenceFrames: \(evidence.frames.count)
              dumpDir: \(previewResult.dumpDirectory.path)
            """
            status = spatialDisparityStatus
            diagnostics.log(spatialDisparityStatus)
            logFirstJointDepthEvidenceFrame()
            buildFusedStereoTargets()
            isBuildingSpatialDisparity = false
            isWorking = false
            finishSpatialDisparityProgress(
                progress: 1,
                text: "Disparity maps complete: \(disparity.frames.count) frames."
            )
            updateDisparityProgress(
                phase: .success,
                fraction: 1,
                title: "Disparity Map Complete",
                detail: "Built \(disparity.frames.count) frames. Evidence frames: \(evidence.frames.count).",
                currentFrame: disparity.frames.count,
                totalFrames: disparity.frames.count,
                validPercent: firstValidPercent
            )
            updateSpatialSolveReadiness()
            diagnostics.log("""
            Spatial disparity build SUCCESS:
              frames: \(disparity.frames.count)
              previewFrames: \(previewResult.previewCapture.frames.count)
              jointDepthEvidenceFrames: \(evidence.frames.count)
            """)
            return true
        } catch {
            spatialDisparityMapCapture = nil
            spatialDisparityPreviewCapture = nil
            jointDepthEvidenceCapture = nil
            spatialRayPinDepthMode = .leftEyeRayPinningFallback
            resetFusedStereoTargetState(status: "Fused target build unavailable: disparity build failed.")
            spatialDisparityStatus = "Spatial disparity build FAILED: \(error.localizedDescription)"
            status = spatialDisparityStatus
            diagnostics.log(spatialDisparityStatus)
            isBuildingSpatialDisparity = false
            isWorking = false
            finishSpatialDisparityProgress(
                progress: 0,
                text: "Disparity build failed."
            )
            updateDisparityProgress(
                phase: .failed,
                fraction: 0,
                title: "Disparity Map Failed",
                detail: error.localizedDescription,
                currentFrame: spatialDisparityCurrentFrame,
                totalFrames: spatialDisparityTotalFrames
            )
            updateSpatialSolveReadiness()
            diagnostics.log("""
            Spatial disparity build FAILED:
              error: \(error.localizedDescription)
            """)
            return false
        }
    }

    private func logFirstJointDepthEvidenceFrame() {
        guard let first = jointDepthEvidenceCapture?.frames.first else {
            diagnostics.log("Joint depth evidence not built: stereo capture or left normalized capture missing.")
            return
        }

        let pass = first.joints.values.filter(\.passesDepthValidation).count
        let fail = first.joints.values.filter { !$0.passesDepthValidation }.count
        let noSample = first.joints.values.filter { $0.disparityDepthMeters == nil }.count
        let examples = first.joints
            .sorted { $0.key < $1.key }
            .prefix(12)
            .map {
                let disparity = $0.value.disparityDepthMeters.map { String(format: "%.3f", $0) } ?? "nil"
                return "\($0.key): winner=\($0.value.winningCandidateSource ?? "nil") depth=\(disparity) conf=\(String(format: "%.2f", $0.value.disparityConfidence)) candidates=\($0.value.candidates.count) status=\($0.value.status)"
            }
            .joined(separator: "\n")

        diagnostics.log("""
        Candidate disparity evidence first frame:
          joints: \(first.joints.count)
          pass: \(pass)
          fail: \(fail)
          noDisparitySample: \(noSample)
          examples:
          \(examples)
        """)
    }

    func buildFusedStereoTargets() {
        guard let left = normalizedLeftCapture,
              let right = normalizedRightCapture else {
            fusedStereoTargetStatus = "Fused target build failed: missing left/right normalized captures."
            diagnostics.log(fusedStereoTargetStatus)
            return
        }

        let metadata = effectiveSpatialMetadata()

        guard metadata.baselineMeters != nil,
              metadata.horizontalFOVDegrees != nil,
              metadata.imageWidth > 0,
              metadata.imageHeight > 0 else {
            fusedStereoTargetStatus = """
            Fused target build failed: missing spatial camera metadata.
              baselineMeters: \(metadata.baselineMeters.map { "\($0)" } ?? "nil")
              horizontalFOVDegrees: \(metadata.horizontalFOVDegrees.map { "\($0)" } ?? "nil")
              imageWidth: \(metadata.imageWidth)
              imageHeight: \(metadata.imageHeight)
            """
            diagnostics.log(fusedStereoTargetStatus)
            return
        }

        let stereo = stereoJointCapture
        let evidence = jointDepthEvidenceCapture

        let fused = StereoJointTargetFuser.fuse(
            left: left,
            right: right,
            stereo: stereo,
            depthEvidence: evidence,
            metadata: metadata,
            yConvention: stereoYConvention,
            settings: stereoTargetFusionSettings,
            rigProfile: referenceRigProfile
        )

        guard !fused.frames.isEmpty else {
            fusedStereoJointTargetCapture = nil
            fusedStereoTargetStatus = "Fused target build failed: no fused frames were produced."
            diagnostics.log(fusedStereoTargetStatus)
            return
        }

        fusedStereoJointTargetCapture = fused

        let first = fused.frames.first
        let accepted = first?.joints.values.filter { !$0.rejected }.count ?? 0
        let rejected = first?.joints.values.filter(\.rejected).count ?? 0
        let held = first?.joints.values.filter { $0.status.contains("held") }.count ?? 0
        let examples = first?.joints
            .sorted { $0.key < $1.key }
            .prefix(10)
            .map {
                let depthDelta = $0.value.visionDisparityDepthDeltaMeters
                    .map { String(format: "%.3f", $0) } ?? "nil"
                return "\($0.key): status=\($0.value.status) conf=\(String(format: "%.2f", $0.value.confidence)) depthDelta=\(depthDelta)"
            }
            .joined(separator: "\n") ?? ""

        fusedStereoTargetStatus = """
        Fused stereo targets built:
          frames: \(fused.frames.count)
          firstFrameJoints: \(first?.joints.count ?? 0)
          stereoFrames: \(stereo?.frames.count ?? 0)
          depthEvidenceFrames: \(evidence?.frames.count ?? 0)
          activeSolveTargetMode: \(solveTargetMode.rawValue)
        """
        status = fusedStereoTargetStatus

        diagnostics.log(fusedStereoTargetStatus)
        diagnostics.log("""
        Fused target first frame:
          accepted: \(accepted)
          rejected: \(rejected)
          held: \(held)
          examples:
          \(examples)
        """)
    }

    func cachedFrames(from frames: [VideoFrame]) -> [RotoVideoFrameCache.CachedFrame] {
        frames.map {
            RotoVideoFrameCache.CachedFrame(
                id: $0.id,
                frameIndex: $0.frameIndex,
                timeSeconds: $0.timeSeconds,
                image: $0.image
            )
        }
    }

    private func effectiveSpatialMetadata() -> SpatialVideoCameraMetadata {
        var metadata = spatialVideoMetadata ?? SpatialVideoCameraMetadata(
            baselineMeters: nil,
            horizontalFOVDegrees: nil,
            verticalFOVDegrees: nil,
            disparityAdjustment: nil,
            imageWidth: leftEyeFrames.first.map { Int($0.image.size.width.rounded()) } ?? 1,
            imageHeight: leftEyeFrames.first.map { Int($0.image.size.height.rounded()) } ?? 1
        )

        if useManualSpatialCameraOverrides,
           spatialBaselineMeters > 0 {
            metadata.baselineMeters = spatialBaselineMeters
        }

        if useManualSpatialCameraOverrides,
           spatialHorizontalFOVDegrees > 0 {
            metadata.horizontalFOVDegrees = spatialHorizontalFOVDegrees
        }

        if useManualSpatialCameraOverrides,
           spatialVerticalFOVDegrees > 0 {
            metadata.verticalFOVDegrees = spatialVerticalFOVDegrees
        }

        if useManualSpatialCameraOverrides {
            metadata.disparityAdjustment = spatialDisparityAdjustment
        }

        if let first = leftEyeFrames.first {
            metadata.imageWidth = max(
                CVPixelBufferGetWidth(first.pixelBuffer),
                1
            )
            metadata.imageHeight = max(
                CVPixelBufferGetHeight(first.pixelBuffer),
                1
            )
        } else if let firstDiagnostic = spatialLeftEyeFrames.first?.diagnostic {
            metadata.imageWidth = max(firstDiagnostic.pixelWidth, 1)
            metadata.imageHeight = max(firstDiagnostic.pixelHeight, 1)
        }

        return metadata
    }

    func playVideo() {
        guard !decodedFrames.isEmpty else {
            videoPlaybackStatus = "Cannot play: no decoded frames."
            diagnostics.log("Cannot play video: decodedFrames is empty.")
            return
        }

        stopFramePlayback()

        let currentTime = decodedFrames[min(currentFrameIndex, decodedFrames.count - 1)].timeSeconds
        playbackStartHostTime = Date()
        playbackStartVideoTime = currentTime

        audioPlayer?.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        audioPlayer?.play()

        isFramePlaybackRunning = true
        videoPlaybackStatus = "Playing"

        diagnostics.log("""
        Playback started from source timestamps:
          startFrame: \(currentFrameIndex)
          startVideoTime: \(playbackStartVideoTime)
          frameCount: \(decodedFrames.count)
          firstTime: \(decodedFrames.first?.timeSeconds ?? -1)
          lastTime: \(decodedFrames.last?.timeSeconds ?? -1)
          estimatedFPS: \(String(format: "%.3f", RotoVideoFrameCache.estimatedFPS(frames: decodedFrames)))
          loop: \(isVideoLooping)
        """)

        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updatePlaybackFrameFromClock()
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
        }
    }

    func pauseVideo() {
        stopFramePlayback()
        audioPlayer?.pause()
        videoPlaybackStatus = "Paused"
    }

    func restartVideo() {
        setCurrentFrameIndex(0)
        playVideo()
    }

    func togglePlayPause() {
        if isFramePlaybackRunning {
            pauseVideo()
        } else {
            playVideo()
        }
    }

    private func updatePlaybackFrameFromClock() {
        guard isFramePlaybackRunning,
              !decodedFrames.isEmpty,
              let playbackStartHostTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(playbackStartHostTime)
        let wallClockTime = playbackStartVideoTime + elapsed
        let playerSeconds = audioPlayer.map { CMTimeGetSeconds($0.currentTime()) }
        var targetTime = wallClockTime

        if let playerSeconds, playerSeconds.isFinite {
            targetTime = playerSeconds
        }

        let firstTime = decodedFrames.first?.timeSeconds ?? 0
        let lastTime = decodedFrames.last?.timeSeconds ?? 0
        let duration = max(lastTime - firstTime, 0.001)

        if targetTime > lastTime {
            if isVideoLooping {
                let relative = targetTime - firstTime
                let looped = relative.truncatingRemainder(dividingBy: duration)
                targetTime = firstTime + looped
                self.playbackStartHostTime = Date()
                self.playbackStartVideoTime = targetTime
                audioPlayer?.seek(
                    to: CMTime(seconds: targetTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                audioPlayer?.play()
            } else {
                setCurrentFrameIndex(decodedFrames.count - 1, resetPlaybackClock: false)
                pauseVideo()
                videoPlaybackStatus = "Ended"
                return
            }
        }

        let frameIndex = nearestDisplayFrameIndex(forTime: targetTime)

        if frameIndex != currentFrameIndex {
            setCurrentFrameIndex(frameIndex, resetPlaybackClock: false)
        }
    }

    private func nearestDisplayFrameIndex(forTime time: Double) -> Int {
        guard !decodedFrames.isEmpty else {
            return 0
        }

        if time <= decodedFrames[0].timeSeconds {
            return 0
        }

        let lastIndex = decodedFrames.count - 1

        if time >= decodedFrames[lastIndex].timeSeconds {
            return lastIndex
        }

        var low = 0
        var high = lastIndex

        while low <= high {
            let mid = (low + high) / 2
            let midTime = decodedFrames[mid].timeSeconds

            if midTime < time {
                low = mid + 1
            } else if midTime > time {
                high = mid - 1
            } else {
                return mid
            }
        }

        let upper = min(low, lastIndex)
        let lower = max(upper - 1, 0)
        let lowerDistance = abs(decodedFrames[lower].timeSeconds - time)
        let upperDistance = abs(decodedFrames[upper].timeSeconds - time)

        return lowerDistance <= upperDistance ? lower : upper
    }

    private func stopFramePlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackStartHostTime = nil
        isFramePlaybackRunning = false
    }

    private func installAudioEndObserver(for item: AVPlayerItem) {
        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
            self.audioEndObserver = nil
        }

        audioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.isVideoLooping {
                    self.setCurrentFrameIndex(0, resetPlaybackClock: false)
                    self.playbackStartHostTime = Date()
                    self.playbackStartVideoTime = self.decodedFrames.first?.timeSeconds ?? 0
                    self.audioPlayer?.play()
                } else {
                    self.stopFramePlayback()
                    self.videoPlaybackStatus = "Ended"
                }
            }
        }
    }

    private func releaseCurrentVideoAccess() {
        stopFramePlayback()

        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
            self.audioEndObserver = nil
        }

        audioPlayer?.pause()
        audioPlayer = nil

        if videoSecurityScopedAccessActive,
           let videoSecurityScopedURL {
            videoSecurityScopedURL.stopAccessingSecurityScopedResource()
        }

        videoSecurityScopedURL = nil
        videoSecurityScopedAccessActive = false
    }

    func runVisionExtraction() async {
        diagnostics.log("""
        Run Vision requested:
          videoURL: \(videoURL?.path ?? "nil")
          decodedFrames: \(decodedFrames.count)
          currentImage exists: \(currentVideoFrameImage != nil)
          visionSampleFPS: \(visionSampleFPS)
        """)

        guard let videoURL else {
            let reason = "Cannot run Vision: videoURL is nil."
            diagnostics.log(reason)
            status = reason
            lastVisionError = reason
            return
        }

        if captureMode == .spatialVideo {
            await runVisionOnSpatialVideo()
            return
        }

        isWorking = true
        status = "Running Apple Vision pose extraction..."
        lastVisionError = nil

        do {
            let capture = try await exporter.runExtraction(
                videoURL: videoURL,
                sampleFPS: visionSampleFPS,
                maxFrames: 0
            )

            rawCapture = capture
            normalizedCapture = nil
            smoothedCapture = nil
            fitResult = nil
            currentRaySolveResult = nil
            rayAnimationSolveResult = nil
            sessionArmatureSnapshot = nil
            sessionArmaturePoseBuffer = nil
            sessionPoseSource = .none
            sessionPoseStatus = "No session pose source detected."
            raySolveStatus = "Ray solve not run."
            rayAnimationSolveStatus = "Ray animation solve not run."
            raySolvedUSDZExportStatus = "No ray solve USDZ exported."
            usdzRetargetStatus = "No animated target USDZ exported."
            lastAnimatedUSDZExportURL = nil
            lastAnimatedUSDZExportFolderURL = nil
            maxFrameIndex = max(maxFrameIndex, max(0, capture.frames.count - 1))
            if currentFrameIndex > maxFrameIndex {
                setCurrentFrameIndex(maxFrameIndex)
            }

            let detectedCount = capture.frames.filter { $0.detected }.count
            status = "Vision extraction complete: \(capture.frames.count) frames."
            log("Vision extraction complete: \(capture.frames.count) frames.")
            isWorking = false

            diagnostics.log("""
            Vision extraction success:
              rawCapture set: \(rawCapture != nil)
              frames: \(capture.frames.count)
              visionSampleFPS: \(visionSampleFPS)
              detectedFrames: \(detectedCount)
              first frame joints: \(capture.frames.first?.joints.count ?? 0)
              Normalize enabled: \(normalizeDisabledReason == nil)
              Normalize disabled reason: \(normalizeDisabledReason ?? "none")
            """)

            if rawCapture == nil {
                diagnostics.log("ERROR: Vision reported success but rawCapture is nil.")
            }
        } catch {
            rawCapture = nil
            lastVisionError = error.localizedDescription
            status = "Vision extraction failed."
            log("Vision extraction failed: \(error.localizedDescription)")
            isWorking = false

            diagnostics.log("""
            Vision extraction FAILED:
              error: \(error)
              rawCapture set: \(rawCapture != nil)
              Normalize disabled reason: \(normalizeDisabledReason ?? "none")
            """)
        }

    }

    func normalize() {
        diagnostics.log("""
        Normalize requested:
          rawCapture exists: \(rawCapture != nil)
          rawFrames: \(rawCapture?.frames.count ?? 0)
        """)

        guard let rawCapture else {
            let reason = "Cannot normalize: rawCapture is nil."
            diagnostics.log(reason)
            status = reason
            lastNormalizeError = reason
            return
        }

        guard !rawCapture.frames.isEmpty else {
            let reason = "Cannot normalize: rawCapture has 0 frames."
            diagnostics.log(reason)
            status = reason
            lastNormalizeError = reason
            return
        }

        normalizedCapture = PoseNormalizer.normalize(rawCapture: rawCapture)
        smoothedCapture = nil
        fitResult = nil
        currentRaySolveResult = nil
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        sessionPoseSource = .none
        sessionPoseStatus = "No session pose source detected."
        raySolveStatus = "Ray solve not run."
        rayAnimationSolveStatus = "Ray animation solve not run."
        raySolvedUSDZExportStatus = "No ray solve USDZ exported."
        usdzRetargetStatus = "No animated target USDZ exported."
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        maxFrameIndex = max(maxFrameIndex, max(0, (normalizedCapture?.frames.count ?? 0) - 1))
        let frameCount = normalizedCapture?.frames.count ?? 0
        let firstJointCount = normalizedCapture?.frames.first?.joints.count ?? 0
        lastNormalizeError = nil
        status = "Normalized to Meshy24: \(frameCount) frames."
        log("Normalized \(rawCapture.frames.count) frames to Meshy/Jock 24.")

        diagnostics.log("""
        Normalize success:
          normalizedCapture set: \(normalizedCapture != nil)
          frames: \(frameCount)
          first frame joint count: \(firstJointCount)
          expected canonical count: \(CanonicalRig.jointNames.count)
          Smoothing enabled: \(smoothingDisabledReason == nil)
          Smoothing disabled reason: \(smoothingDisabledReason ?? "none")
        """)

        if normalizedCapture == nil {
            diagnostics.log("ERROR: Normalize reported success but normalizedCapture is nil.")
        }

    }

    func smooth() {
        diagnostics.log("""
        Smoothing requested:
          normalizedCapture exists: \(normalizedCapture != nil)
          normalizedFrames: \(normalizedCapture?.frames.count ?? 0)
          smoothing global: \(smoothingSettings.globalEnabled)
          smoothing strength: \(smoothingSettings.strength)
        """)

        guard let normalizedCapture else {
            let reason = "Cannot smooth: normalizedCapture is nil."
            diagnostics.log(reason)
            status = reason
            lastSmoothingError = reason
            return
        }

        guard !normalizedCapture.frames.isEmpty else {
            let reason = "Cannot smooth: normalizedCapture has 0 frames."
            diagnostics.log(reason)
            status = reason
            lastSmoothingError = reason
            return
        }

        let settings = SmoothedMeshyPoseCapture.SmoothingSettings(
            globalEnabled: smoothingPreviewEnabled,
            strength: smoothingStrength,
            windowRadius: smoothingWindowRadius,
            missingInterpolationEnabled: smoothingSettings.missingInterpolationEnabled,
            confidenceWeighted: smoothingSettings.confidenceWeighted,
            perJointEnabled: smoothingSettings.perJointEnabled
        )
        smoothingSettings = settings

        smoothedCapture = PoseSmoother2D.smooth(
            normalized: normalizedCapture,
            settings: settings
        )
        fitResult = nil
        currentRaySolveResult = nil
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        sessionPoseSource = .none
        sessionPoseStatus = "No session pose source detected."
        raySolveStatus = "Ray solve not run."
        rayAnimationSolveStatus = "Ray animation solve not run."
        raySolvedUSDZExportStatus = "No ray solve USDZ exported."
        usdzRetargetStatus = "No animated target USDZ exported."
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        let frameCount = smoothedCapture?.frames.count ?? 0
        let firstJointCount = smoothedCapture?.frames.first?.joints.count ?? 0
        let firstDeltaMagnitude: Double = {
            guard let joint = smoothedCapture?.frames.first?.joints.values.first else {
                return 0
            }

            return hypot(joint.deltaX, joint.deltaY)
        }()

        lastSmoothingError = nil
        status = "Smoothing complete: \(frameCount) frames."
        log("Smoothing complete: strength \(String(format: "%.2f", smoothingStrength)), radius \(smoothingWindowRadius).")

        diagnostics.log("""
        Smoothing success:
          smoothedCapture set: \(smoothedCapture != nil)
          frames: \(frameCount)
          first frame joint count: \(firstJointCount)
          first delta magnitude: \(firstDeltaMagnitude)
        """)

        if smoothedCapture == nil {
            diagnostics.log("ERROR: Smoothing reported success but smoothedCapture is nil.")
        }
    }

    func recomputeSmoothingIfAvailable() {
        guard normalizedCapture != nil else { return }
        smooth()
    }

    func importRigProfile() {
        guard let url = FilePanelHelpers.openJSONURL() else { return }

        do {
            rigProfile = try RigProfileLoader.loadRigProfile(from: url)
            reportRigValidation(source: url.lastPathComponent)
        } catch {
            status = "Rig import failed."
            log("Rig import failed: \(error.localizedDescription)")
        }
    }

    func loadDefaultRigProfile() {
        do {
            rigProfile = try RigProfileLoader.loadBundledDefaultProfile()
            reportRigValidation(source: "bundled Meshy24 placeholder")
        } catch {
            status = "Default rig load failed."
            log("Default rig load failed: \(error.localizedDescription)")
        }
    }

    func importUSDZRig() {
        diagnostics.log("Load USDZ Rig requested.")

        guard let url = FilePanelHelpers.openRigAssetURL() else {
            diagnostics.log("Rig load canceled by user.")
            rigImportStatus = "Rig load canceled."
            status = rigImportStatus
            log(rigImportStatus)
            return
        }

        diagnostics.log("Selected rig: \(url.path)")

        importedRigScene = nil
        rigImportStatus = "Loading rig: \(url.lastPathComponent)..."
        status = rigImportStatus
        log(rigImportStatus)

        let didAccess = url.startAccessingSecurityScopedResource()
        diagnostics.log("Rig security scoped access: \(didAccess)")

        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 4101,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Selected rig file does not exist: \(url.path)"
                    ]
                )
            }

            let rig = try USDZRigSceneLoader.loadRigScene(
                from: url,
                defaultOpacity: CGFloat(rigOpacity)
            )

            importedRigScene = rig
            showImportedRigModel = rig.geometryNodeCount > 0
            lastRigError = nil
            if let measuredProfile = rig.measuredRigProfile {
                rigProfile = measuredProfile
            }

            if rig.validation.valid {
                rigImportStatus = """
                Loaded rig: \(url.lastPathComponent)
                Geometry nodes: \(rig.geometryNodeCount)
                Required joints valid.
                Matched joints: \(rig.skeletonJointNames.count)
                """
            } else {
                let missing = rig.validation.missingRequiredJoints.joined(separator: ", ")
                rigImportStatus = """
                Loaded model: \(url.lastPathComponent)
                Geometry nodes: \(rig.geometryNodeCount)
                Matched joints: \(rig.skeletonJointNames.count)
                Model loaded; skeleton mapping missing required joints: \(missing)
                """
            }

            status = rigImportStatus
            log(rigImportStatus)
            if rig.measuredRigProfile != nil {
                log("Derived measured rig profile from imported USD scene nodes.")
            }

            diagnostics.log("""
            Rig load success:
              importedRigScene set: \(importedRigScene != nil)
              geometryNodes: \(rig.geometryNodeCount)
              matchedJoints: \(rig.skeletonJointNames.count)
              missingRequired: \(rig.validation.missingRequiredJoints.joined(separator: ", "))
              showImportedRigModel: \(showImportedRigModel)
            """)

            print(
                """
                [RotoMotion Rig] Loaded rig
                  url: \(url.path)
                  geometries: \(rig.geometryNodeCount)
                  matched: \(rig.skeletonJointNames.count)
                  missingRequired: \(rig.validation.missingRequiredJoints.joined(separator: ", "))
                  nodeCount: \(rig.validation.allImportedNodeNames.count)
                """
            )
        } catch {
            importedRigScene = nil
            lastRigError = error.localizedDescription
            rigImportStatus = """
            Rig/model load failed: \(url.lastPathComponent)
            \(error.localizedDescription)
            """
            status = rigImportStatus
            log(rigImportStatus)

            diagnostics.log("""
            Rig load FAILED:
              url: \(url.path)
              error: \(error)
              importedRigScene set: \(importedRigScene != nil)
            """)

            print(
                """
                [RotoMotion Rig] FAILED
                  url: \(url.path)
                  error: \(error)
                """
            )
        }
    }

    func updateImportedRigOpacity() {
        guard let importedRigScene else { return }

        USDZRigSceneLoader.applyTransparency(
            rootNode: importedRigScene.rootNode,
            opacity: CGFloat(rigOpacity)
        )
    }

    func runFit() {
        guard let normalizedCapture else {
            log("Need normalized capture before rig fitting.")
            return
        }

        guard let rigProfile else {
            log("Import a rig profile before fitting.")
            return
        }

        fitResult = ConstrainedRigFitter.fit(
            normalized: normalizedCapture,
            smoothed: smoothedCapture,
            rigProfile: rigProfile,
            settings: fitSettings,
            groundPlane: groundPlane
        )
        status = "Rig fit complete."
        log("Constrained rig fit complete: \(fitResult?.frames.count ?? 0) frames.")
    }

    func saveRawJSON() {
        guard let rawCapture else {
            log("No raw capture to save.")
            return
        }

        saveJSON(rawCapture, defaultFileName: "capture_raw_vision.json", label: "raw Vision")
    }

    func saveNormalizedJSON() {
        guard let normalizedCapture else {
            log("No normalized capture to save.")
            return
        }

        saveJSON(normalizedCapture, defaultFileName: "capture_normalized_meshy24.json", label: "normalized Meshy24")
    }

    func saveSmoothedJSON() {
        guard let smoothedCapture else {
            log("No smoothed capture to save.")
            return
        }

        saveJSON(smoothedCapture, defaultFileName: "capture_smoothed_meshy24.json", label: "smoothed Meshy24")
    }

    func saveRigProfileJSON() {
        guard let rigProfile else {
            log("No rig profile to save.")
            return
        }

        saveJSON(rigProfile, defaultFileName: "rig_profile_meshy24.json", label: "rig profile")
    }

    func saveFitJSON() {
        guard let fitResult else {
            log("No fit result to save.")
            return
        }

        saveJSON(fitResult, defaultFileName: "capture_fit_meshy24.json", label: "fit result")
    }

    func exportJockAnim() {
        guard let fitResult else {
            log("Run rig fit before JockAnim export.")
            return
        }

        guard let url = FilePanelHelpers.saveJSONURL(
            defaultDirectory: outputDirectoryURL,
            defaultFileName: "rotomotion_test.jockanim.json"
        ) else {
            return
        }

        outputDirectoryURL = url.deletingLastPathComponent()

        do {
            try JockAnimExporter.export(
                fitResult: fitResult,
                clipID: RotoMotionProjectStore.defaultClipID(for: videoURL),
                displayName: videoURL?.deletingPathExtension().lastPathComponent ?? "RotoMotion Test",
                fps: rawCapture?.extraction.sampleFPS ?? sampleFPS,
                looping: false,
                to: url
            )
            status = "JockAnim export complete."
            log("Wrote \(url.lastPathComponent)")
        } catch {
            status = "JockAnim export failed."
            log("JockAnim export failed: \(error.localizedDescription)")
        }
    }

    func chooseReferenceSolveUSDZ() {
        guard let url = FilePanelHelpers.openUSDZURL() else {
            usdzRetargetStatus = "Reference USDZ selection canceled."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        referenceSolveUSDZURL = url
        referenceRigProfile = nil
        sessionSkeletonPath = nil
        sessionJointPaths = []
        sessionJointLeafNames = []
        sessionSkeletonStatus = "No session skeleton captured."
            skinnedRigSession = nil
            invalidateStereoToRigAlignment("reference USDZ changed")
            skinnedRigStatus = "Reference skinned rig cleared because reference USDZ changed."
        referenceRigPlacementStatus = "Reference rig not placed."
        referenceRigVisibilityStatus = "Reference rig not fitted."
        useCalibratedRigDepth = false
        calibratedRigDepthZ = 0
        projectionScaleError = 0
        depthCalibrationStatus = "Depth calibration cleared because reference USDZ changed."
        rayAnimationSolveResult = nil
        sessionArmatureSnapshot = nil
        sessionArmaturePoseBuffer = nil
        sessionPoseSource = .none
        sessionPoseStatus = "No session pose source detected."
        rayAnimationSolveStatus = "Ray animation solve cleared because reference USDZ changed."
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        usdzRetargetStatus = "Selected reference USDZ: \(url.lastPathComponent)"
        status = usdzRetargetStatus
        diagnostics.log("Selected reference solve USDZ: \(url.path)")

        inspectReferenceUSDZ()
        loadSkinnedRigUSDZFromReference(url)
    }

    func loadSkinnedRigUSDZFromReference(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let viewportRigURL: URL
            let viewportRigDescription: String

            if let pythonExecutablePath = openUSDToolStatus?.pythonExecutablePath ?? checkedOpenUSDPythonForRetarget(requireUSDZip: true) {
                do {
                    let opacityWorkDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "rotomotion_reference_opacity_\(UUID().uuidString)",
                            isDirectory: true
                        )

                    let transparentURL = try USDZReferenceOpacityPreprocessor.makeTransparentReferenceUSDZ(
                        sourceUSDZ: url,
                        opacity: 0.5,
                        workDirectory: opacityWorkDir,
                        pythonExecutablePath: pythonExecutablePath
                    )

                    viewportRigURL = transparentURL
                    viewportRigDescription = transparentURL.lastPathComponent

                    diagnostics.log(
                        """
                        Reference viewport USDZ opacity preprocessed:
                        original: \(url.path)
                        transparentCopy: \(transparentURL.path)
                        opacity: 0.5
                        python: \(pythonExecutablePath)
                        """
                    )
                } catch {
                    viewportRigURL = url
                    viewportRigDescription = "\(url.lastPathComponent) (original; opacity preprocessing failed)"

                    diagnostics.log(
                        """
                        Reference viewport opacity preprocessing failed. Loading original USDZ so placement stays visible.
                        original: \(url.path)
                        error: \(error.localizedDescription)
                        """
                    )
                }
            } else {
                viewportRigURL = url
                viewportRigDescription = "\(url.lastPathComponent) (original; OpenUSD Python unavailable)"

                diagnostics.log(
                    """
                    Reference viewport opacity preprocessing skipped. Loading original USDZ so placement stays visible.
                    original: \(url.path)
                    reason: OpenUSD Python unavailable.
                    """
                )
            }

            let unitScale = Float(referenceRigProfile?.unitScaleToMeters ?? 1.0)
            let session = try SkinnedUSDZRigLoader.load(
                url: viewportRigURL,
                originalSourceURL: url,
                unitScaleToMeters: unitScale,
                sceneUnitsPerMeter: Float(raySceneUnitsPerMeter),
                yawCorrectionRadians: 0,
                defaultRigZ: -2.0
            )

            skinnedRigSession = session
            showSkinnedRig = true
            showSkinnedGeometry = true
            if targetCharacterUSDZURL == nil {
                targetCharacterUSDZURL = url
            }
            sessionArmaturePoseBuffer = nil
            bakedRigAnimation = nil
            bakedRigAnimationStatus = "Reference rig loaded. Bake rig animation before export."
            sessionArmatureSnapshot = nil
            referenceRigPlacementStatus = """
            Reference rig loaded.
            Default placement:
            position (0.000, -0.750, -2.000)
            scale (1.000, 1.000, 1.000)
            rotationX -90.0
            rotationY 360.0
            """
            referenceRigVisibilityStatus = "Reference rig loaded with hardcoded viewport placement."

            skinnedRigStatus = """
            Loaded reference skinned rig:
            \(url.lastPathComponent)
            viewport source: \(viewportRigDescription)
            matched bones: \(session.validBoneCount)
            """

            sessionPoseSource = .posedArmatureLocalTransforms
            sessionPoseStatus = """
            Viewport is using real SCNSkinner bone nodes.
            Solve/export will bake and sample those bone-node local transforms.
            """

            status = skinnedRigStatus
            diagnostics.log(skinnedRigStatus)
            diagnostics.log(referenceRigPlacementStatus)
            diagnostics.log(sessionPoseStatus)

            fitReferenceRigHipsSpineIfPossible()
            calibrateStereoToRigAlignmentIfPossible()
        } catch {
            skinnedRigSession = nil
            invalidateStereoToRigAlignment("skinned rig load failed")
            sessionArmaturePoseBuffer = nil
            sessionArmatureSnapshot = nil
            skinnedRigStatus = """
            Reference USDZ loaded for solving, but skinned viewport load failed:
            \(error.localizedDescription)
            """

            if rayAnimationSolveResult == nil {
                sessionPoseSource = .none
                sessionPoseStatus = "No session pose source detected."
            }

            status = skinnedRigStatus
            diagnostics.log(skinnedRigStatus)
        }
    }

    func fitReferenceRigHipsSpineIfPossible() {
        guard let session = skinnedRigSession else {
            diagnostics.log("Hips<->Spine fit skipped: no skinnedRigSession.")
            return
        }

        applyCurrentReferenceRigDisplayTransform(to: session)

        guard let frame = currentNormalizedFrame ?? normalizedCapture?.frames.first else {
            diagnostics.log("Hips<->Spine fit skipped: no normalized frame.")
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            diagnostics.log("Hips<->Spine fit skipped: no videoPlaneSize.")
            return
        }

        guard let result = ReferenceRigHipsSpineFitter.fit(
            session: session,
            normalizedFrame: frame,
            cameraOrigin: SIMD3<Float>(0, 0, cameraZ),
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: currentVideoPlaneZ
        ) else {
            diagnostics.log("Hips<->Spine fit failed: missing Hips/Spine data.")
            return
        }

        let correctedPosition = result.finalRootPosition
        session.displayRootNode.simdPosition = correctedPosition

        referenceRigX = Double(correctedPosition.x)
        referenceRigY = Double(correctedPosition.y)
        referenceRigZ = Double(correctedPosition.z)
        referenceRigCurrentZ = correctedPosition.z

        referenceRigPlacementStatus = """
        Reference Hips<->Spine fit applied:
          fittedZ: \(String(format: "%.4f", result.fittedZ))
          error: \(String(format: "%.6f", result.error))
          targetLength: \(String(format: "%.6f", result.targetLength))
          projectedLength: \(String(format: "%.6f", result.projectedLength))
          fitRootPosition: \(result.finalRootPosition)
          finalRootPosition: \(correctedPosition)
        """

        diagnostics.log(referenceRigPlacementStatus)
    }

    private func applyCurrentReferenceRigDisplayTransform(
        to session: SkinnedRigSession
    ) {
        session.displayRootNode.simdPosition = SIMD3<Float>(
            Float(referenceRigX),
            Float(referenceRigY),
            Float(referenceRigZ)
        )
        session.displayRootNode.simdScale = SIMD3<Float>(1, 1, 1)
        session.displayRootNode.simdEulerAngles = SIMD3<Float>(
            -Float.pi / 2.0,
            Float.pi * 2.0,
            0
        )
        session.correctionNode.simdEulerAngles = SIMD3<Float>(0, 0, 0)
    }

    private func invalidateBakedAnimationBecauseRotationOverridesChanged() {
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Bake is stale. Re-bake animation."
        sessionIsDirty = true
    }

    func refreshSelectedJointEulerFields() {
        let joint = selectedRotationJoint
        let eulerRadians = liveRotationOverrideEulerXYZByJoint[joint]
            ?? heldRotationOverrideEulerXYZByJoint[joint]
            ?? currentBoneEuler(for: joint)
            ?? SIMD3<Float>(0, 0, 0)

        isUpdatingEulerFieldsFromSelection = true
        selectedJointEulerDegreesX = Double(eulerRadians.x) * radiansToDegrees
        selectedJointEulerDegreesY = Double(eulerRadians.y) * radiansToDegrees
        selectedJointEulerDegreesZ = Double(eulerRadians.z) * radiansToDegrees
        isUpdatingEulerFieldsFromSelection = false
    }

    func setSelectedJointEulerDegrees(
        x: Double? = nil,
        y: Double? = nil,
        z: Double? = nil
    ) {
        guard !isUpdatingEulerFieldsFromSelection else {
            return
        }

        if let x {
            selectedJointEulerDegreesX = x
        }

        if let y {
            selectedJointEulerDegreesY = y
        }

        if let z {
            selectedJointEulerDegreesZ = z
        }

        let joint = selectedRotationJoint
        var eulerRadians = SIMD3<Float>(
            Float(selectedJointEulerDegreesX * degreesToRadians),
            Float(selectedJointEulerDegreesY * degreesToRadians),
            Float(selectedJointEulerDegreesZ * degreesToRadians)
        )

        eulerRadians = ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: eulerRadians
        )

        liveRotationOverrideEulerXYZByJoint[joint] = eulerRadians
        liveRotationPreviewFrameIndexByJoint[joint] = currentFrameIndex
        heldRotationOverrideEulerXYZByJoint[joint] = eulerRadians
        rotationOverrideRevision &+= 1
        updateExactRotationKeyIfPresent(
            joint: joint,
            frameIndex: currentFrameIndex,
            timeSeconds: currentVideoTimeSeconds,
            eulerXYZ: eulerRadians
        )
        isRotationGizmoDragging = true
        invalidateBakeAndRefresh(
            reason: "selected joint Euler changed \(joint) frame \(currentFrameIndex)"
        )

        rotationAuthoringStatus = """
        Manual Euler override for \(joint):
        X \(String(format: "%.2f", Double(eulerRadians.x) * radiansToDegrees))°
        Y \(String(format: "%.2f", Double(eulerRadians.y) * radiansToDegrees))°
        Z \(String(format: "%.2f", Double(eulerRadians.z) * radiansToDegrees))°
        frame \(currentFrameIndex)
        """
        status = rotationAuthoringStatus

        applyCurrentFrameToLiveRig()
        refreshSelectedJointEulerFields()
    }

    @MainActor
    private func updateExactRotationKeyIfPresent(
        joint: String,
        frameIndex: Int,
        timeSeconds: Double,
        eulerXYZ: SIMD3<Float>
    ) {
        var layer = rotationOverrideLayer
        var keys = layer.keyframesByJoint[joint] ?? []

        guard let index = keys.firstIndex(where: { $0.frameIndex == frameIndex }) else {
            rotationOverrideLayer = layer
            return
        }

        keys[index] = JointRotationOverrideLayer.Keyframe(
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            eulerXYZ: [
                Double(eulerXYZ.x),
                Double(eulerXYZ.y),
                Double(eulerXYZ.z)
            ]
        )

        keys.sort { $0.frameIndex < $1.frameIndex }
        layer.keyframesByJoint[joint] = keys
        rotationOverrideLayer = layer
        rotationKeyRevision &+= 1

        diagnostics.log("""
        Rotation key updated from Euler field:
          joint: \(joint)
          frame: \(frameIndex)
          rotationKeyRevision: \(rotationKeyRevision)
          rotationOverrideRevision: \(rotationOverrideRevision)
        """)
    }

    func setViewportRotationOverride(
        joint: String,
        eulerXYZ: SIMD3<Float>
    ) {
        let clamped = ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: eulerXYZ
        )

        liveRotationOverrideEulerXYZByJoint[joint] = clamped
        liveRotationPreviewFrameIndexByJoint[joint] = currentFrameIndex
        heldRotationOverrideEulerXYZByJoint[joint] = clamped
        isRotationGizmoDragging = true
        rotationOverrideRevision &+= 1
        invalidateBakeAndRefresh(
            reason: "viewport rotation override changed \(joint) frame \(currentFrameIndex)"
        )

        if joint == selectedRotationJoint {
            isUpdatingEulerFieldsFromSelection = true
            selectedJointEulerDegreesX = Double(clamped.x) * radiansToDegrees
            selectedJointEulerDegreesY = Double(clamped.y) * radiansToDegrees
            selectedJointEulerDegreesZ = Double(clamped.z) * radiansToDegrees
            isUpdatingEulerFieldsFromSelection = false
        }

        rotationAuthoringStatus = """
        Viewport Euler override for \(joint):
        X \(String(format: "%.2f", Double(clamped.x) * radiansToDegrees))°
        Y \(String(format: "%.2f", Double(clamped.y) * radiansToDegrees))°
        Z \(String(format: "%.2f", Double(clamped.z) * radiansToDegrees))°
        """
        status = rotationAuthoringStatus

        print(
            """
            [RotationGizmo] override changed
              joint: \(joint)
              euler: \(clamped)
              revision: \(rotationOverrideRevision)
            """
        )

        applyCurrentFrameToLiveRig()
    }

    func applyCurrentFrameToLiveRig() {
        guard let session = skinnedRigSession,
              let solvedFrame = currentRaySolvedFrame,
              let normalizedFrame = currentNormalizedFrame,
              let videoPlaneSize = currentVideoPlaneSize else {
            return
        }

        SkinnedRigRotomationDriver.rotomateFrameWithCurvePins(
            solvedFrame,
            normalizedFrame: normalizedFrame,
            session: session,
            cameraOrigin: SIMD3<Float>(0, 0, 0),
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: currentVideoPlaneZ
        )

        applyRotationOverridesToLiveRig()
    }

    func applyRotationOverridesToLiveRig() {
        guard let session = skinnedRigSession else {
            return
        }

        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint],
                  let euler = rotationOverrideEulerForViewportFrame(
                    joint: joint,
                    frameIndex: currentFrameIndex,
                    timeSeconds: currentVideoTimeSeconds
                  ) else {
                continue
            }

            bone.simdEulerAngles = euler
        }
    }

    func applyRotationOverridesToRigForBakeFrame(
        session: SkinnedRigSession,
        frameIndex: Int,
        timeSeconds: Double
    ) {
        for joint in CanonicalRig.jointNames {
            guard let bone = session.bonesByCanonicalName[joint],
                  let euler = rotationOverrideEulerForBakeFrame(
                    joint: joint,
                    frameIndex: frameIndex,
                    timeSeconds: timeSeconds
                  ) else {
                continue
            }

            bone.simdEulerAngles = euler
        }
    }

    func authoredRotationJoints() -> Set<String> {
        Set(
            rotationOverrideLayer.keyframesByJoint
                .filter { !$0.value.isEmpty }
                .map { $0.key }
        )
    }

    func authoredEulerForFrame(
        joint: String,
        frameIndex: Int
    ) -> SIMD3<Float>? {
        let keys = (rotationOverrideLayer.keyframesByJoint[joint] ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }

        guard !keys.isEmpty else {
            return nil
        }

        if let exact = keys.first(where: { $0.frameIndex == frameIndex }) {
            return eulerFromKey(joint: joint, key: exact)
        }

        if keys.count == 1 {
            return eulerFromKey(joint: joint, key: keys[0])
        }

        if frameIndex <= keys[0].frameIndex {
            return eulerFromKey(joint: joint, key: keys[0])
        }

        if frameIndex >= keys[keys.count - 1].frameIndex {
            return eulerFromKey(
                joint: joint,
                key: keys[keys.count - 1]
            )
        }

        for i in 0..<(keys.count - 1) {
            let a = keys[i]
            let b = keys[i + 1]

            guard frameIndex >= a.frameIndex,
                  frameIndex <= b.frameIndex,
                  let ea = eulerFromKey(joint: joint, key: a),
                  let eb = eulerFromKey(joint: joint, key: b) else {
                continue
            }

            let t = Float(frameIndex - a.frameIndex) / Float(max(b.frameIndex - a.frameIndex, 1))
            let e = ea + (eb - ea) * t

            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: e
            )
        }

        return nil
    }

    private func eulerFromKey(
        joint: String,
        key: JointRotationOverrideLayer.Keyframe
    ) -> SIMD3<Float>? {
        guard key.eulerXYZ.count == 3 else {
            return nil
        }

        return ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: SIMD3<Float>(
                Float(key.eulerXYZ[0]),
                Float(key.eulerXYZ[1]),
                Float(key.eulerXYZ[2])
            )
        )
    }

    func rotationOverrideEulerForViewportFrame(
        joint: String,
        frameIndex: Int,
        timeSeconds: Double
    ) -> SIMD3<Float>? {
        JointRotationOverrideApplier.rotationOverrideEuler(
            joint: joint,
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            overrideLayer: rotationOverrideLayer,
            heldRotationOverrideEulerXYZByJoint: heldRotationOverrideEulerXYZByJoint,
            liveRotationOverrideEulerXYZByJoint: liveRotationOverrideEulerXYZByJoint,
            liveRotationPreviewFrameIndexByJoint: liveRotationPreviewFrameIndexByJoint,
            liveOverridesActive: isRotationGizmoDragging
        )
    }

    func rotationOverrideEulerForBakeFrame(
        joint: String,
        frameIndex: Int,
        timeSeconds: Double
    ) -> SIMD3<Float>? {
        if let keyed = authoredEulerForFrame(
            joint: joint,
            frameIndex: frameIndex
        ) {
            return keyed
        }

        if let held = heldRotationOverrideEulerXYZByJoint[joint] {
            return ManualRotationConstraint.clampedEulerXYZ(
                joint: joint,
                values: held
            )
        }

        return nil
    }

    func replaceAuthoredJointRotations(
        _ frame: BakedRigAnimation.Frame,
        authoredJoints: Set<String>,
        frameIndex: Int,
        timeSeconds: Double
    ) -> BakedRigAnimation.Frame {
        var joints = frame.joints

        for joint in authoredJoints {
            guard var existing = joints[joint],
                  let authoredEuler = authoredEulerForFrame(
                    joint: joint,
                    frameIndex: frameIndex
                  ) else {
                continue
            }

            existing.localRotationEulerXYZ = [
                Double(authoredEuler.x),
                Double(authoredEuler.y),
                Double(authoredEuler.z)
            ]

            joints[joint] = existing
        }

        return BakedRigAnimation.Frame(
            frameIndex: frame.frameIndex,
            timeSeconds: frame.timeSeconds,
            joints: joints
        )
    }

    func endViewportRotationGizmoDrag() {
        liveRotationOverrideEulerXYZByJoint[selectedRotationJoint] = nil
        liveRotationPreviewFrameIndexByJoint[selectedRotationJoint] = nil
        isRotationGizmoDragging = false
        rotationOverrideRevision &+= 1
        rotationAuthoringStatus = "\(selectedRotationJoint) held override is active."
        status = rotationAuthoringStatus
        requestViewportRefresh(reason: "viewport rotation gizmo drag ended \(selectedRotationJoint)")
        applyCurrentFrameToLiveRig()
        refreshSelectedJointEulerFields()
    }

    func addRotationKeyForSelectedJoint() {
        let joint = selectedRotationJoint

        var eulerRadians = liveRotationOverrideEulerXYZByJoint[joint]
            ?? heldRotationOverrideEulerXYZByJoint[joint]
            ?? SIMD3<Float>(
                Float(selectedJointEulerDegreesX * degreesToRadians),
                Float(selectedJointEulerDegreesY * degreesToRadians),
                Float(selectedJointEulerDegreesZ * degreesToRadians)
            )

        eulerRadians = ManualRotationConstraint.clampedEulerXYZ(
            joint: joint,
            values: eulerRadians
        )

        let key = JointRotationOverrideLayer.Keyframe(
            frameIndex: currentFrameIndex,
            timeSeconds: currentVideoTimeSeconds,
            eulerXYZ: [
                Double(eulerRadians.x),
                Double(eulerRadians.y),
                Double(eulerRadians.z)
            ]
        )

        var layer = rotationOverrideLayer

        if cleanRotationKeysEnabled {
            layer.keyframesByJoint[joint] = [key]
            rotationAuthoringStatus = "Clean-keyed \(joint): replaced all keys with one key at frame \(currentFrameIndex)."
        } else {
            var keys = layer.keyframesByJoint[joint] ?? []
            keys.removeAll { $0.frameIndex == currentFrameIndex }
            keys.append(key)
            keys.sort { $0.frameIndex < $1.frameIndex }
            layer.keyframesByJoint[joint] = keys
            rotationAuthoringStatus = "Added rotation key for \(joint) at frame \(currentFrameIndex). Total keys: \(keys.count)."
        }

        rotationOverrideLayer = layer

        heldRotationOverrideEulerXYZByJoint[joint] = eulerRadians
        liveRotationOverrideEulerXYZByJoint[joint] = eulerRadians
        liveRotationPreviewFrameIndexByJoint[joint] = currentFrameIndex
        isRotationGizmoDragging = false
        rotationKeyRevision &+= 1
        rotationOverrideRevision &+= 1

        status = rotationAuthoringStatus
        invalidateBakeAndRefresh(
            reason: "rotation key added \(joint) frame \(currentFrameIndex)"
        )
        diagnostics.log("""
        Rotation key added:
          joint: \(joint)
          frame: \(currentFrameIndex)
          time: \(String(format: "%.4f", currentVideoTimeSeconds))
          cleanKeysEnabled: \(cleanRotationKeysEnabled)
          keyCount: \(rotationOverrideLayer.keyframesByJoint[joint]?.count ?? 0)
        """)
        applyCurrentFrameToLiveRig()
        refreshSelectedJointEulerFields()
    }

    func keyCurrentRotationOverride() {
        addRotationKeyForSelectedJoint()
    }

    func clearRotationKeysForSelectedJoint() {
        let joint = selectedRotationJoint
        let oldCount = rotationOverrideLayer.keyframesByJoint[joint]?.count ?? 0

        var layer = rotationOverrideLayer
        layer.keyframesByJoint[joint] = []
        rotationOverrideLayer = layer
        rotationKeyRevision &+= 1
        rotationOverrideRevision &+= 1

        rotationAuthoringStatus = "Cleared \(oldCount) rotation keys for \(joint). Held override remains."
        status = rotationAuthoringStatus
        invalidateBakeAndRefresh(reason: "rotation keys cleared \(joint)")
        diagnostics.log(rotationAuthoringStatus)
        applyCurrentFrameToLiveRig()
        refreshSelectedJointEulerFields()
    }

    func clearAllRotationOverrideForSelectedJoint() {
        let joint = selectedRotationJoint

        var layer = rotationOverrideLayer
        layer.keyframesByJoint[joint] = []
        rotationOverrideLayer = layer
        heldRotationOverrideEulerXYZByJoint[joint] = nil
        liveRotationOverrideEulerXYZByJoint[joint] = nil
        liveRotationPreviewFrameIndexByJoint[joint] = nil
        isRotationGizmoDragging = false
        rotationKeyRevision &+= 1
        rotationOverrideRevision &+= 1

        rotationAuthoringStatus = "Cleared all Euler rotation override data for \(joint)."
        status = rotationAuthoringStatus
        invalidateBakeAndRefresh(reason: "all rotation overrides cleared \(joint)")
        diagnostics.log(rotationAuthoringStatus)
        applyCurrentFrameToLiveRig()
        refreshSelectedJointEulerFields()
    }

    func clearHandAnimationForSelectedJoint() {
        clearAllRotationOverrideForSelectedJoint()
    }

    func currentManualOverrideEuler(for joint: String) -> SIMD3<Float>? {
        rotationOverrideEulerForViewportFrame(
            joint: joint,
            frameIndex: currentFrameIndex,
            timeSeconds: currentVideoTimeSeconds
        )
    }

    func currentBoneEuler(for joint: String) -> SIMD3<Float>? {
        skinnedRigSession?.bonesByCanonicalName[joint]?.simdEulerAngles
    }

    func inspectCurrentJointFrame() {
        guard let session = skinnedRigSession else {
            jointDebugStatus = "No skinned rig session."
            status = jointDebugStatus
            diagnostics.log(jointDebugStatus)
            return
        }

        guard let solvedFrame = currentRaySolvedFrame else {
            jointDebugStatus = "No current ray solved frame."
            status = jointDebugStatus
            diagnostics.log(jointDebugStatus)
            return
        }

        jointDebugFrameIndex = solvedFrame.frameIndex

        let report = SingleFrameRigPoseInspector.inspect(
            session: session,
            solvedFrame: solvedFrame,
            normalizedFrame: currentNormalizedFrame,
            jointNames: [
                "Hips",
                "Spine",
                "neck",
                "Head",
                "LeftShoulder",
                "LeftArm",
                "LeftForeArm",
                "LeftHand",
                "RightShoulder",
                "RightArm",
                "RightForeArm",
                "RightHand",
                "LeftUpLeg",
                "LeftLeg",
                "LeftFoot",
                "RightUpLeg",
                "RightLeg",
                "RightFoot"
            ]
        )

        jointDebugStatus = report.summary
        status = report.summary
        diagnostics.log(report.fullText)
    }

    func logCurrentPoseChains() {
        guard let session = skinnedRigSession else {
            diagnostics.log("Pose chain debug failed: no skinnedRigSession.")
            return
        }

        guard let frame = currentRaySolvedFrame else {
            diagnostics.log("Pose chain debug failed: no currentRaySolvedFrame.")
            return
        }

        let report = RigPoseChainDebugger.makeReport(
            session: session,
            solvedFrame: frame,
            normalizedFrame: currentNormalizedFrame,
            rotationApplyMode: rigRotationApplyMode
        )

        diagnostics.log(report)
    }

    func chooseTargetCharacterUSDZ() {
        guard let url = FilePanelHelpers.openUSDZURL() else {
            usdzRetargetStatus = "Target USDZ selection canceled."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        targetCharacterUSDZURL = url
        lastAnimatedUSDZExportURL = nil
        lastAnimatedUSDZExportFolderURL = nil
        usdzRetargetStatus = """
        Selected target model USDZ:
        \(url.lastPathComponent)

        Target is used only as the model package for export.
        No target preflight.
        No target validation.
        """
        status = usdzRetargetStatus
        diagnostics.log("Selected target model USDZ: \(url.path)")
    }

    func checkOpenUSDToolsForRetarget() {
        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        if toolStatus.ready {
            usdzRetargetStatus = "OpenUSD tools ready: \(toolStatus.pythonExecutablePath ?? "python unknown")"
        } else {
            usdzRetargetStatus = """
            OpenUSD tools missing.
            Python OK: \(toolStatus.pythonOK)
            usdzip OK: \(toolStatus.usdzipOK)
            \(toolStatus.pythonMessage)
            """
        }

        status = usdzRetargetStatus
        diagnostics.log(usdzRetargetStatus)
    }

    func checkOpenUSDToolsForExport() {
        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        if toolStatus.ready {
            usdzRetargetStatus = "OpenUSD tools ready. usdzip: \(toolStatus.usdzipPath ?? "unknown")"
        } else {
            usdzRetargetStatus = """
            OpenUSD tools missing.
            Python OK: \(toolStatus.pythonOK)
            usdzip OK: \(toolStatus.usdzipOK)
            \(toolStatus.pythonMessage)
            """
        }

        status = usdzRetargetStatus
        diagnostics.log(usdzRetargetStatus)
    }

    func inspectReferenceUSDZ() {
        guard let url = referenceSolveUSDZURL else {
            return
        }

        guard let pythonExecutablePath = checkedOpenUSDPythonForRetarget() else {
            return
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let profile = try USDZSkeletonInspector.inspectUSDZ(
                url,
                pythonExecutablePath: pythonExecutablePath
            )
            referenceRigProfile = profile
            captureSessionSkeletonIdentity(from: profile)

            if let height = profile.estimatedHeightMeters, height > 0 {
                rayTargetHeightMeters = height
            }

            usdzRetargetStatus = """
            Reference USDZ inspected.
            Matched: \(profile.canonicalMatchedJoints.count)
            Missing: \(profile.missingCanonicalJoints.isEmpty ? "none" : profile.missingCanonicalJoints.joined(separator: ", "))
            Height: \(profile.estimatedHeightMeters.map { String(format: "%.3f m", $0) } ?? "unknown")
            unitScaleToMeters: \(String(format: "%.4f", profile.unitScaleToMeters ?? 1.0))
            """
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
        } catch {
            referenceRigProfile = nil
            usdzRetargetStatus = "Reference USDZ inspect failed: \(error.localizedDescription)"
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
        }
    }

    func exportAnimatedTargetUSDZFromRaySolve() {
        diagnostics.log("""
        Export Animated Target USDZ requested:
          targetUSDZ: \(targetCharacterUSDZURL?.path ?? "nil")
          clipID: \(retargetClipID)
          bakedFrames: \(bakedRigAnimation?.frames.count ?? 0)
        """)

        guard let bakedRigAnimation else {
            usdzRetargetStatus = "Bake Rig Animation For Export before exporting. No baked rig animation is available."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        guard sessionPoseSource == .posedArmatureLocalTransforms else {
            usdzRetargetStatus = """
            Current viewport is a positional solve display, not a posed armature.
            Skinned USDZ export requires local joint rotations from a real posed armature transform stack.
            Load a skinned USDZ rig so the viewport can pose real SCNSkinner bone nodes before exporting.

            Session pose source:
            \(sessionPoseSource.rawValue)
            """
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        let poseBuffer = bakedRigAnimation.asSessionArmaturePoseBuffer()

        var targetURL: URL

        if let existingTarget = targetCharacterUSDZURL {
            targetURL = existingTarget
        } else if let referenceURL = referenceSolveUSDZURL {
            targetURL = referenceURL
            targetCharacterUSDZURL = referenceURL
            diagnostics.log("No target selected. Using reference USDZ as target package: \(referenceURL.path)")
        } else if let chosen = FilePanelHelpers.openUSDZURL() {
            targetURL = chosen
            targetCharacterUSDZURL = chosen
            diagnostics.log("Target chosen during export: \(chosen.path)")
        } else {
            usdzRetargetStatus = "Export canceled: no target USDZ selected."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        targetURL = exportTargetURLAvoidingViewportCopy(targetURL)
        targetCharacterUSDZURL = targetURL

        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        guard toolStatus.ready,
              let pythonExecutablePath = toolStatus.pythonExecutablePath else {
            usdzRetargetStatus = """
            Cannot export animated USDZ: OpenUSD tools missing.
            Python OK: \(toolStatus.pythonOK)
            usdzip OK: \(toolStatus.usdzipOK)
            \(toolStatus.pythonMessage)
            """
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        guard let outputDir = FilePanelHelpers.chooseOutputDirectory() else {
            usdzRetargetStatus = "Export canceled."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        let safeClipID = retargetClipID
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let workDir = outputDir.appendingPathComponent(
            "\(safeClipID)_animated_usdz_work",
            isDirectory: true
        )

        let didAccessTarget = targetURL.startAccessingSecurityScopedResource()
        let didAccessOutput = outputDir.startAccessingSecurityScopedResource()
        let didAccessReference = referenceSolveUSDZURL?.startAccessingSecurityScopedResource() ?? false

        defer {
            if didAccessTarget {
                targetURL.stopAccessingSecurityScopedResource()
            }

            if didAccessOutput {
                outputDir.stopAccessingSecurityScopedResource()
            }

            if didAccessReference {
                referenceSolveUSDZURL?.stopAccessingSecurityScopedResource()
            }
        }

        do {
            if FileManager.default.fileExists(atPath: workDir.path) {
                try FileManager.default.removeItem(at: workDir)
            }

            try FileManager.default.createDirectory(
                at: workDir,
                withIntermediateDirectories: true
            )

            let sessionPoseJSON = workDir.appendingPathComponent(
                "session_armature_pose.json"
            )

            try SessionArmaturePoseBufferJSONExporter.write(
                buffer: poseBuffer,
                to: sessionPoseJSON
            )

            diagnostics.log("Wrote posed skinned rig armature buffer JSON: \(sessionPoseJSON.path)")

            let viewportSource = skinnedRigSession?.sourceURL
            let originalSource = skinnedRigSession?.originalSourceURL
            let exportUsesOriginalSource: Bool

            if let originalSource {
                exportUsesOriginalSource = targetURL.standardizedFileURL == originalSource.standardizedFileURL
            } else {
                exportUsesOriginalSource = true
            }

            diagnostics.log("""
            Session export source:
              bone local transforms only: true
              includes display placement transform: false
              includes display correction transform: false
              loadedWithConvertToYUp: \(skinnedRigSession?.loadedWithConvertToYUp ?? false)
              exportTargetIsOriginalUSDZ: \(exportUsesOriginalSource)
              viewport source: \(viewportSource?.path ?? "nil")
              original source: \(originalSource?.path ?? "nil")
              export target: \(targetURL.path)
            """)

            if sessionJointPaths.isEmpty {
                if let referenceRigProfile {
                    captureSessionSkeletonIdentity(from: referenceRigProfile)
                } else {
                    captureCanonicalSessionSkeletonIdentity()
                }
            }

            guard !sessionJointPaths.isEmpty else {
                usdzRetargetStatus = """
                No session joint order captured. Cannot export.

                Work dir:
                \(workDir.path)
                """
                status = usdzRetargetStatus
                diagnostics.log(usdzRetargetStatus)
                return
            }

            let sessionSkeletonJSON = workDir.appendingPathComponent(
                "session_skeleton_identity.json"
            )

            try SessionSkeletonIdentityExporter.write(
                skeletonPath: sessionSkeletonPath,
                jointPaths: sessionJointPaths,
                jointLeafNames: sessionJointLeafNames,
                to: sessionSkeletonJSON
            )

            diagnostics.log("Wrote session skeleton identity JSON: \(sessionSkeletonJSON.path)")

            if referenceSolveUSDZURL?.standardizedFileURL == targetURL.standardizedFileURL {
                diagnostics.log("Reference and Target USDZ are the same file. Export must resolve the exact session skeleton path.")
            }

            diagnostics.log("""
            Animated target export:
              Reference USDZ: \(referenceSolveUSDZURL?.path ?? "nil")
              Target USDZ: \(targetURL.path)
              Session skeleton path: \(sessionSkeletonPath ?? "nil")
              Session joint count: \(sessionJointPaths.count)
              Baked frames: \(bakedRigAnimation.frames.count)
            """)

            let exportResult = try RetargetedAnimatedUSDZExporter.exportAnimatedTargetUSDZ(
                targetUSDZ: targetURL,
                sessionSkeletonIdentityJSON: sessionSkeletonJSON,
                solvedAnimationJSON: sessionPoseJSON,
                clipID: retargetClipID,
                includeHipsTranslation: includeHipsTranslationInUSDZ,
                pythonExecutablePath: pythonExecutablePath,
                outputDirectory: outputDir
            )

            lastAnimatedUSDZExportURL = exportResult.outputUSDZ
            lastAnimatedUSDZExportFolderURL = exportResult.outputUSDZ.deletingLastPathComponent()

            let exportedAttributes = try? FileManager.default.attributesOfItem(
                atPath: exportResult.outputUSDZ.path
            )
            let exportedSizeBytes = (exportedAttributes?[.size] as? NSNumber)?.int64Value ?? 0

            usdzRetargetStatus = """
            Exported animated target USDZ file:
            \(exportResult.outputUSDZ.path)
            Size: \(exportedSizeBytes) bytes

            Audit:
            \(exportResult.auditHighSeverityCount) high / \(exportResult.auditIssueCount) total issues
            \(exportResult.auditTextReport.path)
            """
            status = usdzRetargetStatus
            diagnostics.log("""
            Animated target USDZ export complete:
              output: \(exportResult.outputUSDZ.path)
              workDir: \(exportResult.workDirectory.path)
              sessionSkeletonIdentity: \(exportResult.sessionSkeletonIdentityJSON.path)
              raySolveReference: \(exportResult.raySolveReferenceJSON.path)
              sessionArmaturePoseBuffer: \(exportResult.exportInputJSON.path)
              preflight: \(exportResult.preflightJSON.path)
              readback: \(exportResult.readbackJSON.path)
              auditText: \(exportResult.auditTextReport.path)
              auditJSON: \(exportResult.auditJSONReport.path)
              auditIssues: \(exportResult.auditHighSeverityCount) high / \(exportResult.auditIssueCount) total
              target: \(targetURL.lastPathComponent)
              frames: \(bakedRigAnimation.frames.count)
              includeHipsTranslation: \(includeHipsTranslationInUSDZ)
              python: \(pythonExecutablePath)
            """)
            NSWorkspace.shared.activateFileViewerSelecting([exportResult.outputUSDZ])
        } catch {
            lastAnimatedUSDZExportURL = nil
            lastAnimatedUSDZExportFolderURL = nil

            usdzRetargetStatus = """
            Animated target USDZ export failed:
            \(error.localizedDescription)

            Work dir:
            \(workDir.path)
            """
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
        }
    }

    func revealLastAnimatedUSDZExport() {
        if let lastAnimatedUSDZExportURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastAnimatedUSDZExportURL])
            return
        }

        if let lastAnimatedUSDZExportFolderURL {
            NSWorkspace.shared.open(lastAnimatedUSDZExportFolderURL)
            return
        }

        usdzRetargetStatus = "No animated USDZ export to reveal."
        status = usdzRetargetStatus
        diagnostics.log(usdzRetargetStatus)
    }

    func chooseSourceCharacterUSDZ() {
        guard let url = FilePanelHelpers.openUSDZURL() else {
            exportStatus = "Source USDZ selection canceled."
            status = exportStatus
            diagnostics.log(exportStatus)
            return
        }

        sourceCharacterUSDZURL = url
        exportStatus = "Selected source character: \(url.lastPathComponent)"
        status = exportStatus
        diagnostics.log("Selected source character USDZ: \(url.path)")
    }

    func exportPreviewPackage() {
        var missing: [String] = []

        if sourceCharacterUSDZURL == nil {
            missing.append("source character USDZ")
        }

        if normalizedCapture == nil && smoothedCapture == nil {
            missing.append("normalized or smoothed animation")
        }

        guard missing.isEmpty else {
            exportStatus = "Cannot export preview package. Needs: \(missing.joined(separator: ", "))."
            status = exportStatus
            diagnostics.log(exportStatus)
            return
        }

        guard let sourceCharacterUSDZURL else {
            exportStatus = "Cannot export preview package. Source character USDZ URL is missing."
            status = exportStatus
            diagnostics.log(exportStatus)
            return
        }

        guard let outputDir = FilePanelHelpers.chooseOutputDirectory() else {
            exportStatus = "Export canceled."
            status = exportStatus
            diagnostics.log(exportStatus)
            return
        }

        let didAccess = sourceCharacterUSDZURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceCharacterUSDZURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let packageURL = try RotoMotionPreviewPackageExporter.exportPackage(
                sourceCharacterUSDZ: sourceCharacterUSDZURL,
                clipID: exportClipID,
                displayName: exportDisplayName,
                videoURL: videoURL,
                normalized: normalizedCapture,
                smoothed: smoothedCapture,
                rawCapture: rawCapture,
                outputDirectory: outputDir
            )

            exportStatus = "Exported package: \(packageURL.path)"
            status = exportStatus
            diagnostics.log(exportStatus)
            NSWorkspace.shared.open(packageURL)
        } catch {
            exportStatus = "Preview package export failed: \(error.localizedDescription)"
            status = exportStatus
            diagnostics.log("Preview package export failed: \(error)")
        }
    }

    func checkOpenUSDTools() {
        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        if toolStatus.ready {
            animatedUSDZExportStatus = "OpenUSD tools ready."
        } else {
            animatedUSDZExportStatus = """
            OpenUSD tools missing.
            Python OK: \(toolStatus.pythonOK)
            usdzip OK: \(toolStatus.usdzipOK)
            \(toolStatus.pythonMessage)
            """
        }

        status = animatedUSDZExportStatus
        diagnostics.log(animatedUSDZExportStatus)
    }

    func chooseAnimatedUSDZSource() {
        guard let url = FilePanelHelpers.openUSDZURL() else {
            animatedUSDZExportStatus = "Animated USDZ source selection canceled."
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        animatedUSDZSourceURL = url
        animatedUSDZExportStatus = "Selected source USDZ: \(url.lastPathComponent)"
        status = animatedUSDZExportStatus
        diagnostics.log("Selected animated USDZ source: \(url.path)")
    }

    func exportAnimatedUSDZ() {
        guard let source = animatedUSDZSourceURL else {
            animatedUSDZExportStatus = "Choose source USDZ first."
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        guard fitResult != nil || normalizedCapture != nil || smoothedCapture != nil else {
            animatedUSDZExportStatus = "Run Vision and Normalize before animated USDZ export."
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        let toolStatus = OpenUSDToolChecker.check()
        openUSDToolStatus = toolStatus

        guard toolStatus.ready else {
            animatedUSDZExportStatus = """
            OpenUSD tools missing. Cannot export animated USDZ.
            Python OK: \(toolStatus.pythonOK)
            usdzip OK: \(toolStatus.usdzipOK)
            \(toolStatus.pythonMessage)
            """
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        guard let pythonExecutablePath = toolStatus.pythonExecutablePath else {
            animatedUSDZExportStatus = "OpenUSD Python executable missing. Cannot export animated USDZ."
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        guard let outputDir = FilePanelHelpers.chooseOutputDirectory() else {
            animatedUSDZExportStatus = "Animated USDZ export canceled."
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            return
        }

        let didAccessSource = source.startAccessingSecurityScopedResource()

        defer {
            if didAccessSource {
                source.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let output = try AnimatedUSDZExporter.exportAnimatedUSDZ(
                sourceUSDZ: source,
                clipID: animatedUSDZClipID,
                normalized: normalizedCapture,
                smoothed: smoothedCapture,
                fitResult: fitResult,
                pythonExecutablePath: pythonExecutablePath,
                outputDirectory: outputDir
            )

            animatedUSDZExportStatus = "Exported animated USDZ: \(output.path)"
            status = animatedUSDZExportStatus
            diagnostics.log(animatedUSDZExportStatus)
            NSWorkspace.shared.open(output.deletingLastPathComponent())
        } catch {
            animatedUSDZExportStatus = "Animated USDZ export failed: \(error.localizedDescription)"
            status = animatedUSDZExportStatus
            diagnostics.log("Animated USDZ export failed: \(error)")
        }
    }

    func exportRaySolvedArmatureUSDZ() {
        guard let result = rayAnimationSolveResult else {
            raySolvedUSDZExportStatus = "Solve full animation before USDZ export."
            status = raySolvedUSDZExportStatus
            diagnostics.log(raySolvedUSDZExportStatus)
            return
        }

        guard let outputDir = FilePanelHelpers.chooseOutputDirectory() else {
            raySolvedUSDZExportStatus = "Ray solve USDZ export canceled."
            status = raySolvedUSDZExportStatus
            diagnostics.log(raySolvedUSDZExportStatus)
            return
        }

        do {
            let output = try RotoRaySolvedUSDZExporter.exportUSDZ(
                result: result,
                clipID: raySolvedUSDZClipID,
                outputDirectory: outputDir
            )

            lastAnimatedUSDZExportURL = output
            lastAnimatedUSDZExportFolderURL = output.deletingLastPathComponent()

            raySolvedUSDZExportStatus = "Exported ray solve USDZ: \(output.path)"
            status = raySolvedUSDZExportStatus
            diagnostics.log("""
            Ray solve USDZ export complete:
              output: \(output.path)
              frames: \(result.frames.count)
              joints: \(result.frames.first?.jointPositions.count ?? 0)
            """)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            lastAnimatedUSDZExportURL = nil
            lastAnimatedUSDZExportFolderURL = nil

            raySolvedUSDZExportStatus = "Ray solve USDZ export failed: \(error.localizedDescription)"
            status = raySolvedUSDZExportStatus
            diagnostics.log("Ray solve USDZ export failed: \(error)")
        }
    }

    func chooseOutputDirectory() {
        guard let url = FilePanelHelpers.chooseOutputDirectory() else { return }

        outputDirectoryURL = url
        log("Output directory set to \(url.path)")
    }

    func handlePlaybackTimeChange(_ seconds: Double) {
        currentTimeSeconds = seconds

        let frames = rawCapture?.frames
        guard let frames, !frames.isEmpty else {
            return
        }

        let nearestIndex = frames.indices.min { lhs, rhs in
            abs(frames[lhs].timeSeconds - seconds) < abs(frames[rhs].timeSeconds - seconds)
        }

        if let nearestIndex, nearestIndex != currentFrameIndex {
            setCurrentFrameIndex(nearestIndex)
        }
    }

    func setCurrentFrameIndex(
        _ index: Int,
        resetPlaybackClock: Bool = true
    ) {
        guard !decodedFrames.isEmpty else {
            currentFrameIndex = 0
            currentVideoFrameImage = nil
            currentTimeSeconds = 0
            imageRenderToken += 1
            playbackStartVideoTime = 0
            diagnostics.log("setCurrentFrameIndex ignored: decodedFrames empty.")
            return
        }

        let clamped = max(0, min(maxFrameIndex, min(index, decodedFrames.count - 1)))

        currentFrameIndex = clamped
        currentVideoFrameImage = decodedFrames[clamped].image
        currentTimeSeconds = decodedFrames[clamped].timeSeconds
        imageRenderToken += 1

        if resetPlaybackClock {
            playbackStartVideoTime = decodedFrames[clamped].timeSeconds

            if isFramePlaybackRunning {
                playbackStartHostTime = Date()
            }
        }

        diagnostics.log("""
        setCurrentFrameIndex:
          requested: \(index)
          clamped: \(clamped)
          image exists: \(currentVideoFrameImage != nil)
          imageRenderToken: \(imageRenderToken)
          image size: \(String(describing: currentVideoFrameImage?.size))
        """)
    }

    func setCurrentFrameIndex(_ index: Int, seekPlayer: Bool) {
        setCurrentFrameIndex(index, resetPlaybackClock: seekPlayer)
    }

    func stepFrame(_ delta: Int) {
        if isFramePlaybackRunning {
            pauseVideo()
        }

        setCurrentFrameIndex(currentFrameIndex + delta)
    }

    func debugSaveCurrentFramePNG() {
        guard let image = currentVideoFrameImage else {
            diagnostics.log("Debug PNG failed: currentVideoFrameImage nil.")
            return
        }

        guard let tiff = image.tiffRepresentation else {
            diagnostics.log("Debug PNG failed: no TIFF representation.")
            return
        }

        guard let bitmap = NSBitmapImageRep(data: tiff) else {
            diagnostics.log("Debug PNG failed: no bitmap rep.")
            return
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            diagnostics.log("Debug PNG failed: no PNG representation.")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotomotion_current_frame_debug.png")

        do {
            try png.write(to: url)
            diagnostics.log("Saved debug frame PNG: \(url.path)")
            NSWorkspace.shared.open(url)
        } catch {
            diagnostics.log("Debug PNG save failed: \(error.localizedDescription)")
        }
    }

    func resetGroundPlane() {
        groundPlane.reset()
        fitSettings.useGroundConstraint = groundPlane.constraintEnabled
        fitResult = nil
        status = "Ground plane reset."
        log(status)
    }

    private func reportRigValidation(source: String) {
        guard let rigProfile else { return }

        let validation = rigProfile.validate()

        if validation.valid {
            status = "Rig profile loaded and valid."
            log("Loaded rig profile from \(source).")
        } else {
            status = "Rig profile missing required landmarks."
            log("Rig missing: \(validation.missingRequiredJoints.joined(separator: ", "))")
        }
    }

    private func saveJSON<T: Encodable>(
        _ value: T,
        defaultFileName: String,
        label: String
    ) {
        guard let url = FilePanelHelpers.saveJSONURL(
            defaultDirectory: outputDirectoryURL,
            defaultFileName: defaultFileName
        ) else {
            return
        }

        outputDirectoryURL = url.deletingLastPathComponent()

        do {
            try JSONCoding.writePretty(value, to: url)
            status = "Saved \(label)."
            log("Wrote \(url.lastPathComponent)")
        } catch {
            status = "Save failed."
            log("\(label) save failed: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        logLines.append(message)

        if logLines.count > 100 {
            logLines.removeFirst(logLines.count - 100)
        }
    }
}
