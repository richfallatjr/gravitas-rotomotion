import AppKit
import AVFoundation
import Combine
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
        didSet { persist(showRawVisionPoints, AppStorageKeys.showRawVisionPoints) }
    }
    @Published var showNormalizedMeshyPoints = true {
        didSet { persist(showNormalizedMeshyPoints, AppStorageKeys.showNormalizedMeshyPoints) }
    }
    @Published var showSmoothedMeshyPoints = true {
        didSet { persist(showSmoothedMeshyPoints, AppStorageKeys.showSmoothedMeshyPoints) }
    }
    @Published var showSmoothingDeltaVectors = true {
        didSet { persist(showSmoothingDeltaVectors, AppStorageKeys.showSmoothingDeltaVectors) }
    }
    @Published var showImportedRigModel = true {
        didSet { persist(showImportedRigModel, AppStorageKeys.showImportedRigModel) }
    }
    @Published var showImportedRigSkeleton = true {
        didSet { persist(showImportedRigSkeleton, AppStorageKeys.showImportedRigSkeleton) }
    }
    @Published var showFittedRig = true {
        didSet { persist(showFittedRig, AppStorageKeys.showFittedRig) }
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
        didSet { persist(showSkinnedRig, AppStorageKeys.showSkinnedRig) }
    }
    @Published var viewportZoom: Double = 2.0 {
        didSet { persist(viewportZoom, AppStorageKeys.viewportZoom) }
    }
    @Published var cameraProfile: CameraProfile = .iPhone17Main1x {
        didSet { persist(cameraProfile.rawValue, AppStorageKeys.cameraProfile) }
    }
    var activeCameraFOVDegrees: Double {
        cameraProfile.portraitVerticalFOVDegrees
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
    @Published var rotationEditLayer = JointRotationEditLayer.default {
        didSet { persistCodable(rotationEditLayer, AppStorageKeys.rotationEditLayer) }
    }
    @Published var selectedRotationJoint = "Head" {
        didSet {
            rotationEditLayer.selectedJoint = selectedRotationJoint
            persist(selectedRotationJoint, AppStorageKeys.selectedRotationJoint)
        }
    }
    @Published var cleanRotationKeysEnabled = false {
        didSet {
            rotationEditLayer.cleanKeysEnabled = cleanRotationKeysEnabled
            if suppressSessionDirtyTracking {
                persist(cleanRotationKeysEnabled, AppStorageKeys.cleanRotationKeysEnabled)
                return
            }

            bakedRigAnimation = nil
            bakedRigAnimationStatus = "Rotation edit mode changed. Bake rig animation before export."
            sessionIsDirty = true
            applyCurrentFrameToLiveRig()
            persist(cleanRotationKeysEnabled, AppStorageKeys.cleanRotationKeysEnabled)
        }
    }
    @Published var rotationAuthoringStatus = "No rotation key." {
        didSet { persist(rotationAuthoringStatus, AppStorageKeys.rotationAuthoringStatus) }
    }
    @Published var liveRotationDeltaByJoint: [String: SIMD4<Float>] = [:]
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
        didSet { persist(showVisionRays, AppStorageKeys.showVisionRays) }
    }
    @Published var showRaySolvedRig = true {
        didSet { persist(showRaySolvedRig, AppStorageKeys.showRaySolvedRig) }
    }
    @Published var showDebugSolvedSkeleton = false {
        didSet { persist(showDebugSolvedSkeleton, AppStorageKeys.showDebugSolvedSkeleton) }
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
        static let rotationEditLayer = prefix + "rotationEditLayer"
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

    private func loadPersistedAppStorageFields() {
        suppressSessionDirtyTracking = true
        defer {
            suppressSessionDirtyTracking = false
        }

        videoURL = storedURL(AppStorageKeys.videoURL)
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
        if let value = storedCodable(JointRotationEditLayer.self, AppStorageKeys.rotationEditLayer) {
            rotationEditLayer = value
            selectedRotationJoint = value.selectedJoint
            cleanRotationKeysEnabled = value.cleanKeysEnabled
        }
        if let value = storedString(AppStorageKeys.selectedRotationJoint) { selectedRotationJoint = value }
        if let value = storedBool(AppStorageKeys.cleanRotationKeysEnabled) { cleanRotationKeysEnabled = value }
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
            rotationEditLayer: rotationEditLayer,
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
                skinnedRigStatus = "Reference USDZ path from session no longer exists: \(path)"
                diagnostics.log(skinnedRigStatus)
            }
        } else {
            referenceSolveUSDZURL = nil
            skinnedRigSession = nil
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

        rotationEditLayer = document.rotationEditLayer
        selectedRotationJoint = document.selectedRotationJoint
        cleanRotationKeysEnabled = document.cleanRotationKeysEnabled
        rotationEditLayer.selectedJoint = selectedRotationJoint
        rotationEditLayer.cleanKeysEnabled = cleanRotationKeysEnabled
        liveRotationDeltaByJoint = [:]

        rotationAuthoringStatus = "Loaded rotation edit layer."
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

    func solveFullAnimationWithCameraRays() {
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

        fitReferenceRigHipsSpineIfPossible()

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
        } catch {
            skinnedRigSession = nil
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

        var frames: [BakedRigAnimation.Frame] = []

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

            JointRotationEditApplier.apply(
                to: session,
                editLayer: rotationEditLayer,
                liveRotationDeltaByJoint: liveRotationDeltaByJoint,
                timeSeconds: solvedFrame.timeSeconds
            )

            frames.append(
                BakedRigAnimationSampler.sample(
                    session: session,
                    frameIndex: solvedFrame.frameIndex,
                    timeSeconds: solvedFrame.timeSeconds,
                    jointNames: session.jointOrder
                )
            )
        }

        let baked = BakedRigAnimation(
            schema: "com.gravitas.rotomotion.baked_rig_animation.v0",
            clipID: retargetClipID,
            fps: inferredFPS(solve.frames),
            jointNames: session.jointOrder,
            frames: frames
        )

        bakedRigAnimation = baked
        sessionArmaturePoseBuffer = baked.asSessionArmaturePoseBuffer()
        sessionPoseSource = .posedArmatureLocalTransforms
        sessionPoseStatus = "Baked immutable rig animation from live curve-pinned pose: \(frames.count) frames."
        bakedRigAnimationStatus = "Baked \(frames.count) frames for export."
        usdzRetargetStatus = bakedRigAnimationStatus
        status = bakedRigAnimationStatus
        diagnostics.log(bakedRigAnimationStatus)
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
        } catch {
            skinnedRigSession = nil
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

        guard let frame = currentNormalizedFrame ?? normalizedCapture?.frames.first else {
            diagnostics.log("Hips<->Spine fit skipped: no normalized frame.")
            return
        }

        guard let videoPlaneSize = currentVideoPlaneSize else {
            diagnostics.log("Hips<->Spine fit skipped: no videoPlaneSize.")
            return
        }

        applyCurrentReferenceRigDisplayTransform(to: session)

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

        referenceRigX = Double(result.finalRootPosition.x)
        referenceRigY = Double(result.finalRootPosition.y)
        referenceRigZ = Double(result.finalRootPosition.z)
        referenceRigCurrentZ = result.finalRootPosition.z

        referenceRigPlacementStatus = """
        Reference Hips<->Spine fit applied:
          fittedZ: \(String(format: "%.4f", result.fittedZ))
          error: \(String(format: "%.6f", result.error))
          targetLength: \(String(format: "%.6f", result.targetLength))
          projectedLength: \(String(format: "%.6f", result.projectedLength))
          finalRootPosition: \(result.finalRootPosition)
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

    func applyRotationOrbiterDrag(
        dx: CGFloat,
        dy: CGFloat
    ) {
        let joint = selectedRotationJoint
        let sensitivity: Float = 0.01
        let yaw = simd_quatf(
            angle: Float(dx) * sensitivity,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let pitch = simd_quatf(
            angle: Float(dy) * sensitivity,
            axis: SIMD3<Float>(1, 0, 0)
        )
        let increment = yaw * pitch
        let current = liveRotationDeltaByJoint[joint]
            .map(JointRotationEditApplier.quatFromWXYZ)
            ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let updated = increment * current

        liveRotationDeltaByJoint[joint] = SIMD4<Float>(
            updated.vector.w,
            updated.vector.x,
            updated.vector.y,
            updated.vector.z
        )

        rotationAuthoringStatus = "Editing \(joint)"
        status = rotationAuthoringStatus
        sessionIsDirty = true
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Rotation edits changed. Bake rig animation before export."
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

        applyRotationEditLayerToLiveRig()
    }

    func applyRotationEditLayerToLiveRig() {
        guard let session = skinnedRigSession else {
            return
        }

        JointRotationEditApplier.apply(
            to: session,
            editLayer: rotationEditLayer,
            liveRotationDeltaByJoint: liveRotationDeltaByJoint,
            timeSeconds: currentVideoTimeSeconds
        )
    }

    func keyCurrentRotationEdit() {
        let joint = selectedRotationJoint

        guard let delta = liveRotationDeltaByJoint[joint] else {
            rotationAuthoringStatus = "No live rotation delta for \(joint)."
            return
        }

        let key = JointRotationEditLayer.Keyframe(
            frameIndex: currentFrameIndex,
            timeSeconds: currentVideoTimeSeconds,
            deltaRotationWXYZ: [
                Double(delta.x),
                Double(delta.y),
                Double(delta.z),
                Double(delta.w)
            ]
        )

        if cleanRotationKeysEnabled {
            rotationEditLayer.keyframesByJoint[joint] = [key]
            rotationAuthoringStatus = "Clean-keyed \(joint) with one held key."
        } else {
            var keys = rotationEditLayer.keyframesByJoint[joint] ?? []
            keys.removeAll { $0.frameIndex == currentFrameIndex }
            keys.append(key)
            keys.sort { $0.timeSeconds < $1.timeSeconds }
            rotationEditLayer.keyframesByJoint[joint] = keys
            rotationAuthoringStatus = "Keyed \(joint) at frame \(currentFrameIndex)."
        }

        status = rotationAuthoringStatus
        liveRotationDeltaByJoint[joint] = nil
        sessionIsDirty = true
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Rotation edits changed. Bake rig animation before export."
        diagnostics.log(rotationAuthoringStatus)
    }

    func clearRotationKeysForSelectedJoint() {
        rotationEditLayer.keyframesByJoint[selectedRotationJoint] = []
        liveRotationDeltaByJoint[selectedRotationJoint] = nil
        rotationAuthoringStatus = "Cleared keys for \(selectedRotationJoint)."
        status = rotationAuthoringStatus
        sessionIsDirty = true
        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Rotation edits changed. Bake rig animation before export."
        diagnostics.log(rotationAuthoringStatus)
        applyCurrentFrameToLiveRig()
    }

    func cleanAllRotationKeysForSelectedJoint() {
        let joint = selectedRotationJoint
        let oldCount = rotationEditLayer.keyframesByJoint[joint]?.count ?? 0

        // Rotation edit cleanup only.
        // Does not modify ray-solved positions, normalized joints, or curve-pinned solve data.
        rotationEditLayer.keyframesByJoint[joint] = []
        liveRotationDeltaByJoint[joint] = nil

        rotationAuthoringStatus = """
        Cleaned all rotation keys for \(joint).
        Removed \(oldCount) keys.
        """

        bakedRigAnimation = nil
        bakedRigAnimationStatus = "Rotation edits changed. Bake rig animation before export."
        status = rotationAuthoringStatus
        sessionIsDirty = true
        diagnostics.log(rotationAuthoringStatus)
        applyCurrentFrameToLiveRig()
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
          raySolveExists: \(rayAnimationSolveResult != nil)
          solvedFrames: \(rayAnimationSolveResult?.frames.count ?? 0)
        """)

        guard let solve = rayAnimationSolveResult,
              !solve.frames.isEmpty else {
            usdzRetargetStatus = "Run full ray animation solve before exporting."
            status = usdzRetargetStatus
            diagnostics.log(usdzRetargetStatus)
            return
        }

        if sessionPoseSource == .none {
            sessionPoseSource = .drawnJointPositions
            sessionPoseStatus = """
            Ray solve exists, but no posed armature local-transform buffer has been captured.
            Treating the viewport source as drawn joint positions.
            """
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

        guard let bakedRigAnimation else {
            usdzRetargetStatus = "Bake rig animation before export."
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
              Solved frames: \(solve.frames.count)
            """)

            let exportResult = try RetargetedAnimatedUSDZExporter.exportAnimatedTargetUSDZ(
                targetUSDZ: targetURL,
                sessionSkeletonIdentityJSON: sessionSkeletonJSON,
                solvedAnimationJSON: sessionPoseJSON,
                solve: solve,
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
              frames: \(solve.frames.count)
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
