import Foundation

struct JointRotationOverrideLayer: Codable {
    let schema: String
    var selectedJoint: String
    var cleanKeysEnabled: Bool
    var keyframesByJoint: [String: [Keyframe]]

    struct Keyframe: Codable, Identifiable {
        var id: String { "\(frameIndex)" }

        let frameIndex: Int
        let timeSeconds: Double

        /// Absolute replacement local Euler XYZ radians.
        var eulerXYZ: [Double]

        enum CodingKeys: String, CodingKey {
            case frameIndex
            case timeSeconds
            case eulerXYZ
            case axisValuesXYZ
        }

        init(
            frameIndex: Int,
            timeSeconds: Double,
            eulerXYZ: [Double]
        ) {
            self.frameIndex = frameIndex
            self.timeSeconds = timeSeconds
            self.eulerXYZ = eulerXYZ
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            frameIndex = try container.decode(Int.self, forKey: .frameIndex)
            timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)

            if let euler = try container.decodeIfPresent([Double].self, forKey: .eulerXYZ),
               euler.count == 3 {
                eulerXYZ = euler
            } else if let legacyAxis = try container.decodeIfPresent([Double].self, forKey: .axisValuesXYZ),
                      legacyAxis.count == 3 {
                eulerXYZ = legacyAxis
            } else {
                eulerXYZ = [0, 0, 0]
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frameIndex, forKey: .frameIndex)
            try container.encode(timeSeconds, forKey: .timeSeconds)
            try container.encode(eulerXYZ, forKey: .eulerXYZ)
        }
    }

    static let `default` = JointRotationOverrideLayer(
        schema: "com.gravitas.rotomotion.rotation_override_layer.v0",
        selectedJoint: "Head",
        cleanKeysEnabled: false,
        keyframesByJoint: [:]
    )
}
