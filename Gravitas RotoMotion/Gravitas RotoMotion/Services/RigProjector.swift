import CoreGraphics
import Foundation

struct RigProjectionSettings: Codable, Equatable {
    var root2D: CGPoint
    var scale: Double
    var orientationMode: OrientationMode

    enum OrientationMode: String, Codable, CaseIterable {
        case front
        case back
        case leftProfile
        case rightProfile
        case threeQuarterFrontLeft
        case threeQuarterFrontRight
        case threeQuarterBackLeft
        case threeQuarterBackRight
        case custom
    }

    static let `default` = RigProjectionSettings(
        root2D: CGPoint(x: 0.5, y: 0.5),
        scale: 1.0,
        orientationMode: .front
    )
}

enum RigProjector {
    static func project(
        fittedPose: RigFitResult.FrameFit,
        settings: RigProjectionSettings
    ) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]

        for (joint, position) in fittedPose.jointPositions3D {
            let x = settings.root2D.x + CGFloat(position.x) * settings.scale
            let y = settings.root2D.y - CGFloat(position.z) * settings.scale
            result[joint] = CGPoint(x: x, y: y)
        }

        return result
    }
}
