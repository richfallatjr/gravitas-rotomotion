import Foundation
import simd

enum PoseExtractionMode: String, Codable, CaseIterable, Identifiable {
    case vision2D
    case vision3D
    case spatialStereo
    case disparityGuidedRayPin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vision2D:
            return "Vision 2D"
        case .vision3D:
            return "Vision 3D"
        case .spatialStereo:
            return "Spatial Stereo"
        case .disparityGuidedRayPin:
            return "Disparity Ray Pin"
        }
    }
}

enum Skin3DSource: String, Codable, CaseIterable, Identifiable {
    case auto
    case vision3D
    case spatialDepthGuidedRayPin
    case monocularRayPinLegacy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .vision3D:
            return "Vision 3D"
        case .spatialDepthGuidedRayPin:
            return "Spatial Disparity Ray Pin"
        case .monocularRayPinLegacy:
            return "Monocular Ray Pin Legacy"
        }
    }
}

enum LiveRigPoseSource: String, Codable {
    case none
    case skin3DVision3D
    case skin3DSpatialDepthGuidedRayPin
    case skin3DMonocularLegacy
    case bakedRigAnimationPlayback
}

struct Vision3DSkinningAlignmentState: Codable {
    var valid: Bool
    var scale: Float
    var rotationWXYZ: [Float]
    var translationXYZ: [Float]

    static let invalid = Vision3DSkinningAlignmentState(
        valid: false,
        scale: 1,
        rotationWXYZ: [1, 0, 0, 0],
        translationXYZ: [0, 0, 0]
    )
}

struct Vision3DBodyPoseCapture: Codable {
    let schema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: Joint]
        let bodyHeightMeters: Double?
        let heightEstimation: String?
        let cameraOriginMatrix: [Double]?
        let valid: Bool
        let status: String
    }

    struct Joint: Codable {
        let name: String
        let positionXYZMeters: [Double]
        let localPositionXYZMeters: [Double]?
        let projectedX: Double?
        let projectedY: Double?
        let confidence: Double
        let parentName: String?
        let valid: Bool
    }

    static let currentSchema = "com.gravitas.rotomotion.vision3d_body_pose.v0"
}

struct NormalizedVision3DMeshyCapture: Codable {
    let schema: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: Joint]
    }

    struct Joint: Codable {
        let x: Double
        let y: Double
        let z: Double
        let projectedX: Double?
        let projectedY: Double?
        let confidence: Double
        let source: String
        let inferred: Bool
    }

    static let currentSchema = "com.gravitas.rotomotion.normalized_vision3d_meshy.v0"
}

struct Vision3DComparisonReport {
    let frameIndex: Int
    let validVision3DJoints: Int
    let averageProjected2DError: Double?
    let averageBoneLengthVariation: Double?
    let worstBone: String?
    let worstBoneVariation: Double?
}
