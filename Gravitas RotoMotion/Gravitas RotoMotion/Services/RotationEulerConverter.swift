import Foundation
import simd

enum RotationEulerConverter {
    static func eulerXYZ(from quaternion: simd_quatf) -> SIMD3<Float> {
        let vector = quaternion.vector
        let length = simd_length(vector)
        let q = length > 0.000001
            ? vector / length
            : SIMD4<Float>(0, 0, 0, 1)
        let x = q.x
        let y = q.y
        let z = q.z
        let w = q.w

        let roll = atan2(
            2.0 * (w * x + y * z),
            1.0 - 2.0 * (x * x + y * y)
        )
        let pitchInput = max(
            -1.0,
            min(1.0, 2.0 * (w * y - z * x))
        )
        let pitch = asin(pitchInput)
        let yaw = atan2(
            2.0 * (w * z + x * y),
            1.0 - 2.0 * (y * y + z * z)
        )

        return SIMD3<Float>(roll, pitch, yaw)
    }
}
