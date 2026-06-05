import Foundation

struct JointRotationEditLayer: Codable {
    let schema: String
    var selectedJoint: String
    var cleanKeysEnabled: Bool
    var keyframesByJoint: [String: [Keyframe]]

    struct Keyframe: Codable, Identifiable {
        var id: String { "\(frameIndex)" }

        let frameIndex: Int
        let timeSeconds: Double

        /// Additive local-space delta rotation in WXYZ order.
        var deltaRotationWXYZ: [Double]
    }

    static let `default` = JointRotationEditLayer(
        schema: "com.gravitas.rotomotion.rotation_edit_layer.v0",
        selectedJoint: "Head",
        cleanKeysEnabled: false,
        keyframesByJoint: [:]
    )
}
