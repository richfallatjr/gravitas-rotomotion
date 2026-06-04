import Foundation
import simd

struct RotoCameraRay: Equatable {
    let jointName: String
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>
    let confidence: Float

    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}
