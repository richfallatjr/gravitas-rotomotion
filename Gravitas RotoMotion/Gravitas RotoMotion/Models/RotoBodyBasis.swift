import Foundation
import simd

struct RotoBodyBasis: Equatable {
    let origin: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let forward: SIMD3<Float>

    static let identity = RotoBodyBasis(
        origin: SIMD3<Float>(0, 0, 0),
        right: SIMD3<Float>(1, 0, 0),
        up: SIMD3<Float>(0, 1, 0),
        forward: SIMD3<Float>(0, 0, 1)
    )
}
