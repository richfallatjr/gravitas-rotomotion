import Foundation
import simd

struct RotoRayIKSolveResult: Equatable {
    let frameIndex: Int
    let timeSeconds: Double
    let jointPositions: [String: SIMD3<Float>]
    let localRotationsWXYZ: [String: SIMD4<Float>]
    let projectionErrors: [String: Float]
    let solvedJoints: Set<String>
    let missingJoints: Set<String>
    let bodyBasis: RotoBodyBasis
}
