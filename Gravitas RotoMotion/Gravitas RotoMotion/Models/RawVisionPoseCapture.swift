import CoreGraphics
import Foundation

struct RawVisionPoseCapture: Codable {
    let schema: String
    let appName: String
    let appVersion: String

    let sourceVideo: SourceVideo
    let extraction: ExtractionMetadata
    let frames: [PoseFrame]
    let canonicalRig: CanonicalRigSnapshot

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
        let canonicalJoints: [String: CanonicalJointObservation]
    }

    struct JointObservation: Codable {
        let x: Double
        let y: Double
        let confidence: Double
    }

    struct CanonicalJointObservation: Codable {
        let x: Double
        let y: Double
        let z: Double
        let confidence: Double
        let sourceVisionJoint: String?
        let generated: Bool
        let note: String?
    }

    struct CanonicalRigSnapshot: Codable {
        let rigID: String
        let rigVersion: String
        let jointCount: Int
        let upAxis: String
        let jointNames: [String]
    }
}
