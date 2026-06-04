import Foundation
import simd

struct RotoRaySolveResult: Equatable {
    let frameIndex: Int
    let joints: [String: SolvedJoint]
    let rays: [String: CameraRay]
    let errors: [String: Double]

    struct SolvedJoint: Equatable {
        let name: String
        let parent: String?
        let worldPosition: SIMD3<Float>
        let solved: Bool
        let note: String
    }

    struct CameraRay: Equatable {
        let jointName: String
        let origin: SIMD3<Float>
        let direction: SIMD3<Float>
        let length: Float

        var end: SIMD3<Float> {
            origin + direction * length
        }
    }
}
