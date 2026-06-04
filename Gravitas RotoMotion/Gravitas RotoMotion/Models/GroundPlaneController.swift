import Foundation
import simd

struct GroundPlaneController: Codable, Equatable {
    var visible: Bool
    var constraintEnabled: Bool
    var opacity: Double
    var size: Double

    /// Screen-space offset in normalized card units. 0 means centered.
    var offsetX: Double
    var offsetY: Double

    /// Solver-space vertical offset.
    var groundHeight: Double

    /// X-axis tumble/pitch in degrees.
    var tumbleXDegrees: Double

    /// Z-axis roll in degrees for unlevel footage.
    var rollZDegrees: Double

    static let `default` = GroundPlaneController(
        visible: true,
        constraintEnabled: true,
        opacity: 0.5,
        size: 2.0,
        offsetX: 0.0,
        offsetY: 0.0,
        groundHeight: 0.0,
        tumbleXDegrees: 55.0,
        rollZDegrees: 0.0
    )

    var tumbleXRadians: Double {
        tumbleXDegrees * Double.pi / 180.0
    }

    var rollZRadians: Double {
        rollZDegrees * Double.pi / 180.0
    }

    mutating func reset() {
        self = .default
    }
}
