import AppKit
import CoreVideo
import Foundation

enum RotoMotionCaptureMode: String, CaseIterable, Identifiable, Codable {
    case monocularVideo
    case spatialVideo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monocularVideo:
            return "Monocular Video"
        case .spatialVideo:
            return "Spatial Video"
        }
    }
}

struct VideoFrame: Identifiable, @unchecked Sendable {
    let id: Int
    let frameIndex: Int
    let timeSeconds: Double
    let image: NSImage
    let pixelBuffer: CVPixelBuffer
}

struct SpatialDecodedFrames {
    let leftFrames: [VideoFrame]
    let rightFrames: [VideoFrame]
    let fps: Double
    let duration: Double
    let metadata: SpatialVideoCameraMetadata
    let stereoDiagnostics: SpatialStereoDecodeResult
}

struct SpatialVideoCameraMetadata: Codable, Equatable, Sendable {
    var baselineMeters: Double?
    var horizontalFOVDegrees: Double?
    var verticalFOVDegrees: Double?
    var disparityAdjustment: Double?
    var imageWidth: Int
    var imageHeight: Int
}

enum ActiveCameraProfileSource: String, Codable {
    case monocularVerticalProfile
    case spatialVideoMetadata
}

struct RotoCameraIntrinsics: Codable, Equatable {
    let source: String
    let imageWidth: Int
    let imageHeight: Int
    let horizontalFOVDegrees: Double
    let verticalFOVDegrees: Double
    let baselineMeters: Double?
}

enum NormalizedImageYConvention: String, CaseIterable, Identifiable, Codable {
    case originBottomLeft
    case originTopLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .originBottomLeft:
            return "Vision bottom-left"
        case .originTopLeft:
            return "Image top-left"
        }
    }
}

enum RotoSolveTargetMode: String, Codable {
    case monocularRayPinned
    case spatialDepthGuidedRayPinned
}

enum SpatialRayPinDepthMode: String, Codable {
    case disparityDepthGuided
    case leftEyeRayPinningFallback
}

enum SpatialSolveReadiness: String, Codable {
    case notSpatial
    case needsVision
    case needsDisparityMap
    case needsJointDepthEvidence
    case ready
}

struct StereoToRigAlignment: Codable, Equatable {
    var isValid: Bool

    /// Converts stereo camera-space meters into the current visible rig scene space.
    var scale: Float
    var translation: SIMD3Codable

    /// Reserved for future calibration. Kept at identity for this patch.
    var rotationYRadians: Float

    static let invalid = StereoToRigAlignment(
        isValid: false,
        scale: 1,
        translation: SIMD3Codable(x: 0, y: 0, z: 0),
        rotationYRadians: 0
    )
}

struct SpatialEyeLayerMap: Codable, Equatable {
    let leftLayerID: Int?
    let rightLayerID: Int?

    static let empty = SpatialEyeLayerMap(
        leftLayerID: nil,
        rightLayerID: nil
    )

    var hasBothEyes: Bool {
        leftLayerID != nil && rightLayerID != nil
    }
}

struct StereoMeshyJointCapture: Codable {
    static let currentSchema = "com.gravitas.rotomotion.stereo_meshy_joints.v0"

    let schema: String
    let cameraMetadata: SpatialVideoCameraMetadata
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: Joint]
    }

    struct Joint: Codable {
        let leftX: Double
        let leftY: Double
        let rightX: Double
        let rightY: Double

        let leftConfidence: Double
        let rightConfidence: Double

        /// Triangulated camera-space position in meters. Camera looks down -Z.
        let positionCameraXYZ: [Double]

        /// Positive depth in meters from the camera.
        let depthMeters: Double

        let stereoConfidence: Double
        let validStereo: Bool
        let rejectReason: String?

        let reprojectedLeftX: Double
        let reprojectedLeftY: Double
        let reprojectedRightX: Double
        let reprojectedRightY: Double
        let reprojectionErrorLeft: Double
        let reprojectionErrorRight: Double
    }
}

struct ConditionedStereoJointCapture: Codable {
    static let currentSchema = "com.gravitas.rotomotion.conditioned_stereo_joints.v0"

    let schema: String
    let sourceSchema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: Joint]
    }

    struct Joint: Codable {
        let positionCameraXYZ: [Double]
        let confidence: Double
        let sourceValidStereo: Bool

        /// How far this conditioned point moved from raw stereo.
        let conditioningDelta: [Double]

        /// Reason this joint was accepted, smoothed, held, or rejected.
        let status: String
    }
}

struct StereoTargetConditioningSettings: Codable {
    var smoothingAlpha: Double = 0.35

    /// Max allowed per-frame jump in meters before treating as a pop.
    var maxFrameJumpMeters: Double = 0.65

    /// If confidence below this, prefer previous valid joint.
    var minConfidence: Double = 0.25

    /// Clamp body-relative depth jumps.
    var maxRelativeDepthJumpMeters: Double = 0.75

    /// Allow holding a joint for a few frames if Vision glitches.
    var maxHoldFrames: Int = 6

    static let `default` = StereoTargetConditioningSettings()
}

struct StereoDisparitySettings: Codable, Sendable {
    /// Downsample scale for disparity computation.
    var scale: Double = 0.25

    /// Patch radius in downsampled pixels.
    var patchRadius: Int = 4

    /// Horizontal search range in downsampled pixels.
    var searchRadius: Int = 48

    /// Step size. 1 is accurate but slower.
    var searchStep: Int = 1

    /// Max normalized block-match cost. Smaller is stricter.
    var maxMatchCost: Double = 0.22

    /// Median sample window around a joint in disparity-map pixels.
    var jointSampleRadius: Int = 5

    /// Relative depth tolerance before a joint fails validation.
    var maxJointDepthDeltaMeters: Double = 0.75

    /// For parent-child direction checks.
    var minDepthDirectionDeltaMeters: Double = 0.12

    /// Whether preview PNGs may be emitted by future diagnostics.
    var dumpPreviewPNGs: Bool = true

    static let `default` = StereoDisparitySettings()
}

struct SpatialDisparityMapCapture: Codable, Sendable {
    static let currentSchema = "com.gravitas.rotomotion.spatial_disparity_map.v0"

    let schema: String
    let cameraMetadata: SpatialVideoCameraMetadata
    let settings: StereoDisparitySettings
    let frames: [Frame]

    struct Frame: Codable, Identifiable, Sendable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double

        /// Disparity/depth map dimensions. Usually downsampled from source video.
        let width: Int
        let height: Int

        /// Row-major Float32 values in disparity-map resolution.
        let disparityPixels: [Float]

        /// Row-major Float32 depth values in meters. Invalid values are NaN.
        let depthMeters: [Float]

        /// Row-major confidence 0...1.
        let confidence: [Float]

        /// Optional grayscale preview PNG path if dumped for diagnostics.
        let previewPNGPath: String?
    }
}

enum DisparityPlateOverlayKind: String, CaseIterable, Codable, Identifiable {
    case depth
    case confidence
    case rawDisparity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .depth:
            return "Depth"
        case .confidence:
            return "Confidence"
        case .rawDisparity:
            return "Raw"
        }
    }
}

struct SpatialDisparityPreviewCapture: Codable, Sendable {
    static let currentSchema = "com.gravitas.rotomotion.spatial_disparity_preview.v0"

    let schema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable, Sendable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double

        let depthPreviewPNGPath: String?
        let confidencePreviewPNGPath: String?
        let rawDisparityPreviewPNGPath: String?

        let validDepthPixels: Int
        let totalPixels: Int
        let minDepthMeters: Double
        let medianDepthMeters: Double
        let maxDepthMeters: Double
    }
}

enum DisparityDepthCandidateSource: String, Codable {
    case leftEyeVision
    case rightEyeVisionOnLeftPlate
    case leftRightLerp
    case stereoReprojectedLeft
    case conditionedReprojectedLeft
    case fusedReprojectedLeft
}

struct DisparityDepthCandidate: Codable {
    let source: DisparityDepthCandidateSource
    let x: Double
    let y: Double
    let depthMeters: Double?
    let confidence: Double
    let status: String
}

struct JointDepthEvidenceCapture: Codable {
    static let currentSchema = "com.gravitas.rotomotion.joint_depth_evidence.v0"

    let schema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: JointEvidence]
    }

    struct JointEvidence: Codable {
        let jointName: String

        /// From Vision left/right joint triangulation.
        let stereoJointDepthMeters: Double?
        let stereoJointConfidence: Double

        /// From local image disparity map sampling around the left-eye joint.
        let disparityDepthMeters: Double?
        let disparityConfidence: Double
        let winningCandidateSource: String?
        let candidates: [DisparityDepthCandidate]

        /// Difference: disparityDepth - stereoJointDepth.
        let depthDeltaMeters: Double?

        /// Whether the depth check passes current thresholds.
        let passesDepthValidation: Bool

        /// Useful for foreshortening: does child-vs-parent depth ordering agree?
        let depthDirectionStatus: String

        let status: String
    }
}

struct StereoTargetFusionSettings: Codable {
    /// How far sparse Vision stereo depth may disagree with disparity before suspect.
    var maxVisionDisparityDepthDeltaMeters: Double = 0.75

    /// Hard temporal pop threshold in meters.
    var maxTemporalJointJumpMeters: Double = 0.85

    /// Joint can be held for this many frames if Vision pops.
    var maxHoldFrames: Int = 6

    /// Envelope width tolerance between left/right reprojections in pixels.
    var maxStereoEnvelopeWidthPixels: Double = 80

    /// Ray-envelope closest-approach tolerance in camera-space meters.
    var maxRaySeparationMeters: Double = 0.35

    /// If disparity is valid, blend target depth toward disparity.
    var disparityDepthBlend: Double = 0.65

    /// Minimum confidence to accept a target without holding.
    var minFusedConfidence: Double = 0.25

    static let `default` = StereoTargetFusionSettings()
}

struct FusedStereoJointTargetCapture: Codable {
    static let currentSchema = "com.gravitas.rotomotion.fused_stereo_targets.v0"

    let schema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: JointTarget]
    }

    struct JointTarget: Codable {
        let jointName: String

        /// Final target used by solver, camera-space meters.
        let positionCameraXYZ: [Double]?

        /// Preferred 2D target on left-eye plate.
        let leftX: Double?
        let leftY: Double?

        /// Preferred 2D target on right-eye plate.
        let rightX: Double?
        let rightY: Double?

        /// Vision stereo triangulation estimate, if valid.
        let visionStereoPositionCameraXYZ: [Double]?

        /// Disparity-derived depth, if valid.
        let disparityDepthMeters: Double?

        /// 0...1 confidence after fusion.
        let confidence: Double

        /// The target should be ignored for this frame.
        let rejected: Bool

        /// Why this target was accepted/rejected/held.
        let status: String

        /// Useful debug signals.
        let visionDisparityDepthDeltaMeters: Double?
        let temporalPopDistanceMeters: Double?
        let stereoEnvelopeWidthPixels: Double?
        let stereoEnvelopeSeparationMeters: Double?
    }
}
