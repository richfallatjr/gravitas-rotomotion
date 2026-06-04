import Foundation

struct RotoMotionPreviewPackage: Codable {
    let schema: String
    let packageID: String
    let createdAtISO8601: String
    let sourceCharacter: SourceCharacter
    let animation: Animation
    let provenance: Provenance

    struct SourceCharacter: Codable {
        let originalFileName: String
        let bundledFileName: String
        let role: String
    }

    struct Animation: Codable {
        let clipID: String
        let displayName: String
        let jockAnimFileName: String
        let rigID: String
        let rigVersion: String
        let fps: Double
        let frameCount: Int
        let durationSeconds: Double
    }

    struct Provenance: Codable {
        let appName: String
        let appVersion: String
        let sourceVideoFileName: String?
        let sourceVideoPath: String?
        let visionFrames: Int
        let normalizedFrames: Int
        let smoothedFrames: Int
        let notes: String
    }
}
