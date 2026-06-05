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
    var rotationOverrideLayer: JointRotationOverrideLayer
    var heldRotationOverrideEulerXYZByJoint: [String: SIMD3Codable]

    var selectedRotationJoint: String
    var cleanRotationKeysEnabled: Bool

    static let currentSchema = "com.gravitas.rotomotion.session.v1"

    init(
        schema: String,
        appVersion: String,
        savedAt: Date,
        clipID: String,
        videoURLPath: String?,
        referenceUSDZPath: String?,
        targetUSDZPath: String?,
        currentFrameIndex: Int,
        currentVideoTimeSeconds: Double,
        cameraProfileRawValue: String,
        cameraFOVDegrees: Double,
        imagePlaneDistance: Double,
        showRawVision: Bool,
        showNormalizedMeshy: Bool,
        showSkinnedRig: Bool,
        showDebugSolvedSkeleton: Bool,
        referenceRigX: Double,
        referenceRigY: Double,
        referenceRigZ: Double,
        referenceRigRotationXDegrees: Double,
        referenceRigRotationYDegrees: Double,
        referenceRigScale: Double,
        rawCapture: RawVisionPoseCapture?,
        normalizedCapture: NormalizedMeshyPoseCapture?,
        rayAnimationSolveResult: RotoRayAnimationSolveResult?,
        bakedRigAnimation: BakedRigAnimation?,
        rotationOverrideLayer: JointRotationOverrideLayer,
        heldRotationOverrideEulerXYZByJoint: [String: SIMD3Codable],
        selectedRotationJoint: String,
        cleanRotationKeysEnabled: Bool
    ) {
        self.schema = schema
        self.appVersion = appVersion
        self.savedAt = savedAt
        self.clipID = clipID
        self.videoURLPath = videoURLPath
        self.referenceUSDZPath = referenceUSDZPath
        self.targetUSDZPath = targetUSDZPath
        self.currentFrameIndex = currentFrameIndex
        self.currentVideoTimeSeconds = currentVideoTimeSeconds
        self.cameraProfileRawValue = cameraProfileRawValue
        self.cameraFOVDegrees = cameraFOVDegrees
        self.imagePlaneDistance = imagePlaneDistance
        self.showRawVision = showRawVision
        self.showNormalizedMeshy = showNormalizedMeshy
        self.showSkinnedRig = showSkinnedRig
        self.showDebugSolvedSkeleton = showDebugSolvedSkeleton
        self.referenceRigX = referenceRigX
        self.referenceRigY = referenceRigY
        self.referenceRigZ = referenceRigZ
        self.referenceRigRotationXDegrees = referenceRigRotationXDegrees
        self.referenceRigRotationYDegrees = referenceRigRotationYDegrees
        self.referenceRigScale = referenceRigScale
        self.rawCapture = rawCapture
        self.normalizedCapture = normalizedCapture
        self.rayAnimationSolveResult = rayAnimationSolveResult
        self.bakedRigAnimation = bakedRigAnimation
        self.rotationOverrideLayer = rotationOverrideLayer
        self.heldRotationOverrideEulerXYZByJoint = heldRotationOverrideEulerXYZByJoint
        self.selectedRotationJoint = selectedRotationJoint
        self.cleanRotationKeysEnabled = cleanRotationKeysEnabled
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case appVersion
        case savedAt
        case clipID
        case videoURLPath
        case referenceUSDZPath
        case targetUSDZPath
        case currentFrameIndex
        case currentVideoTimeSeconds
        case cameraProfileRawValue
        case cameraFOVDegrees
        case imagePlaneDistance
        case showRawVision
        case showNormalizedMeshy
        case showSkinnedRig
        case showDebugSolvedSkeleton
        case referenceRigX
        case referenceRigY
        case referenceRigZ
        case referenceRigRotationXDegrees
        case referenceRigRotationYDegrees
        case referenceRigScale
        case rawCapture
        case normalizedCapture
        case rayAnimationSolveResult
        case bakedRigAnimation
        case rotationOverrideLayer
        case heldRotationOverrideEulerXYZByJoint
        case selectedRotationJoint
        case cleanRotationKeysEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schema = try container.decode(String.self, forKey: .schema)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        clipID = try container.decode(String.self, forKey: .clipID)
        videoURLPath = try container.decodeIfPresent(String.self, forKey: .videoURLPath)
        referenceUSDZPath = try container.decodeIfPresent(String.self, forKey: .referenceUSDZPath)
        targetUSDZPath = try container.decodeIfPresent(String.self, forKey: .targetUSDZPath)
        currentFrameIndex = try container.decode(Int.self, forKey: .currentFrameIndex)
        currentVideoTimeSeconds = try container.decode(Double.self, forKey: .currentVideoTimeSeconds)
        cameraProfileRawValue = try container.decode(String.self, forKey: .cameraProfileRawValue)
        cameraFOVDegrees = try container.decode(Double.self, forKey: .cameraFOVDegrees)
        imagePlaneDistance = try container.decode(Double.self, forKey: .imagePlaneDistance)
        showRawVision = try container.decode(Bool.self, forKey: .showRawVision)
        showNormalizedMeshy = try container.decode(Bool.self, forKey: .showNormalizedMeshy)
        showSkinnedRig = try container.decode(Bool.self, forKey: .showSkinnedRig)
        showDebugSolvedSkeleton = try container.decode(Bool.self, forKey: .showDebugSolvedSkeleton)
        referenceRigX = try container.decode(Double.self, forKey: .referenceRigX)
        referenceRigY = try container.decode(Double.self, forKey: .referenceRigY)
        referenceRigZ = try container.decode(Double.self, forKey: .referenceRigZ)
        referenceRigRotationXDegrees = try container.decode(Double.self, forKey: .referenceRigRotationXDegrees)
        referenceRigRotationYDegrees = try container.decode(Double.self, forKey: .referenceRigRotationYDegrees)
        referenceRigScale = try container.decode(Double.self, forKey: .referenceRigScale)
        rawCapture = try container.decodeIfPresent(RawVisionPoseCapture.self, forKey: .rawCapture)
        normalizedCapture = try container.decodeIfPresent(NormalizedMeshyPoseCapture.self, forKey: .normalizedCapture)
        rayAnimationSolveResult = try container.decodeIfPresent(
            RotoRayAnimationSolveResult.self,
            forKey: .rayAnimationSolveResult
        )
        bakedRigAnimation = try container.decodeIfPresent(BakedRigAnimation.self, forKey: .bakedRigAnimation)
        rotationOverrideLayer = try container.decode(
            JointRotationOverrideLayer.self,
            forKey: .rotationOverrideLayer
        )
        heldRotationOverrideEulerXYZByJoint = try container.decodeIfPresent(
            [String: SIMD3Codable].self,
            forKey: .heldRotationOverrideEulerXYZByJoint
        ) ?? [:]
        selectedRotationJoint = try container.decode(String.self, forKey: .selectedRotationJoint)
        cleanRotationKeysEnabled = try container.decode(Bool.self, forKey: .cleanRotationKeysEnabled)
    }
}
