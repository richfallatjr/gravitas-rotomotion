import Foundation

struct SmoothedMeshyPoseCapture: Codable {
    let schema: String
    let sourceNormalizedCapturePath: String?
    let smoothingSettings: SmoothingSettings
    let frames: [Frame]

    struct SmoothingSettings: Codable, Equatable {
        var globalEnabled: Bool
        var strength: Double
        var missingInterpolationEnabled: Bool
        var confidenceWeighted: Bool
        var perJointEnabled: [String: Bool]

        static let `default` = SmoothingSettings(
            globalEnabled: true,
            strength: 0.65,
            missingInterpolationEnabled: true,
            confidenceWeighted: true,
            perJointEnabled: Dictionary(
                uniqueKeysWithValues: CanonicalRig.jointNames.map { ($0, true) }
            )
        )
    }

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let timecode: String
        let joints: [String: Joint]
    }

    struct Joint: Codable {
        let rawX: Double
        let rawY: Double
        let smoothedX: Double
        let smoothedY: Double
        let deltaX: Double
        let deltaY: Double
        let confidence: Double
        let smoothingEnabled: Bool
        let missing: Bool
        let generated: Bool
    }
}
