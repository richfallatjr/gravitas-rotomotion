import Foundation

enum RotoMotionProjectStore {
    static func defaultOutputDirectory(for videoURL: URL?) -> URL? {
        videoURL?.deletingLastPathComponent()
    }

    static func defaultClipID(for videoURL: URL?) -> String {
        let base = videoURL?.deletingPathExtension().lastPathComponent ?? "rotomotion_test"
        return base
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
