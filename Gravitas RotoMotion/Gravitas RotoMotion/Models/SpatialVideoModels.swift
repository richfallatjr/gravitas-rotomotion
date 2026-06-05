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

struct SpatialVideoCameraMetadata: Codable, Equatable {
    var baselineMeters: Double?
    var horizontalFOVDegrees: Double?
    var verticalFOVDegrees: Double?
    var disparityAdjustment: Double?
    var imageWidth: Int
    var imageHeight: Int
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
