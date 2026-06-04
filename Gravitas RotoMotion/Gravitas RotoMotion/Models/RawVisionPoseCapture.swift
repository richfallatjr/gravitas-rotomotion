import Foundation

struct RawVisionPoseCapture: Codable {
    let schema: String
    let appName: String
    let appVersion: String

    let sourceVideo: SourceVideo
    let extraction: ExtractionMetadata
    let frames: [PoseFrame]

    struct SourceVideo: Codable {
        let fileName: String
        let filePath: String
        let durationSeconds: Double
        let nominalFrameRate: Double
        let naturalWidth: Int
        let naturalHeight: Int
    }

    struct ExtractionMetadata: Codable {
        let visionRequest: String
        let sampleFPS: Double
        let normalizedCoordinates: Bool
        let createdAtISO8601: String
        let notes: String
    }

    struct PoseFrame: Codable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let sourceFrameIndex: Int?
        let timeSeconds: Double
        let timecode: String
        let detected: Bool
        let joints: [String: JointObservation]
    }

    struct JointObservation: Codable {
        let x: Double
        let y: Double
        let confidence: Double
    }
}
