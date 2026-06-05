import Foundation

enum ManualRotationChannelPolicy {
    static func usesXYZOnly(_ joint: String) -> Bool {
        true
    }

    static func lockedChannelsDescription(for joint: String) -> String {
        "Euler XYZ only"
    }
}
