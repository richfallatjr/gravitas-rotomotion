import Foundation

struct RigFitResult: Codable {
    let schema: String
    let sourceCaptureKind: String
    let rigID: String
    let rigVersion: String
    let frames: [FrameFit]

    struct FrameFit: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let jointPositions3D: [String: SIMD3Codable]
        let localRotationsWXYZ: [String: SIMD4Codable]
        let fitErrors: [String: Double]
        let fitScore: Double
        let ignoredTargets: [String]
    }
}
