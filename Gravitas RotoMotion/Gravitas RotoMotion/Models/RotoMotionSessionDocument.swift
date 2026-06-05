import Foundation

struct RotoMotionSessionDocument: Codable {
    let schema: String
    let appVersion: String
    let savedAt: Date

    var clipID: String

    var videoURLPath: String?
    var referenceUSDZPath: String?
    var targetUSDZPath: String?

    var currentFrameIndex: Int
    var currentVideoTimeSeconds: Double

    var cameraProfileRawValue: String
    var cameraFOVDegrees: Double
    var imagePlaneDistance: Double

    var showRawVision: Bool
    var showNormalizedMeshy: Bool
    var showSkinnedRig: Bool
    var showDebugSolvedSkeleton: Bool

    var referenceRigX: Double
    var referenceRigY: Double
    var referenceRigZ: Double
    var referenceRigRotationXDegrees: Double
    var referenceRigRotationYDegrees: Double
    var referenceRigScale: Double

    var rawCapture: RawVisionPoseCapture?
    var normalizedCapture: NormalizedMeshyPoseCapture?
    var rayAnimationSolveResult: RotoRayAnimationSolveResult?
    var bakedRigAnimation: BakedRigAnimation?
    var rotationEditLayer: JointRotationEditLayer

    var selectedRotationJoint: String
    var cleanRotationKeysEnabled: Bool

    static let currentSchema = "com.gravitas.rotomotion.session.v1"
}
