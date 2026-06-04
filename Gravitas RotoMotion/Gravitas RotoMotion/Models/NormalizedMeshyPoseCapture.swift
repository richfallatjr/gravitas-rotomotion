import Foundation

struct NormalizedMeshyPoseCapture: Codable {
    let schema: String
    let sourceRawCapturePath: String?
    let rigID: String
    let rigVersion: String
    let frames: [Frame]

    struct Frame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let timecode: String
        let joints: [String: Joint]
    }

    struct Joint: Codable {
        let x: Double
        let y: Double
        let z: Double?
        let confidence: Double
        let missing: Bool
        let sourceVisionJoint: String?
        let generated: Bool
        let note: String?
    }
}
