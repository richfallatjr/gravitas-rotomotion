import Foundation
import simd

enum ManualRotationConstraint {
    static func clampedEulerXYZ(
        joint: String,
        values: SIMD3<Float>
    ) -> SIMD3<Float> {
        var v = values

        switch joint {
        case "LeftForeArm", "RightForeArm":
            v.y = max(0, v.y)

        case "LeftLeg", "RightLeg":
            // Knee X cannot go positive.
            // Positive X bends the knee backward for this rig.
            v.x = min(0, v.x)

        default:
            break
        }

        return v
    }

    static func constrainedAxesDescription(for joint: String) -> String {
        switch joint {
        case "LeftForeArm", "RightForeArm":
            return "Y >= 0"
        case "LeftLeg", "RightLeg":
            return "X <= 0"
        default:
            return "none"
        }
    }
}
