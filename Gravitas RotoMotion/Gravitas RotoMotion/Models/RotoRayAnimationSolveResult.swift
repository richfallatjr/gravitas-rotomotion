import Foundation
import simd

struct RotoRayAnimationSolveResult: Codable, Equatable {
    let schema: String
    let rigID: String
    let rigVersion: String
    let sourceKind: String
    let targetHeightMeters: Double
    let sceneUnitsPerMeter: Double
    let armatureSceneScale: Double
    let frameCount: Int
    let frames: [Frame]

    struct Frame: Codable, Equatable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let jointPositions: [String: SIMD3<Float>]
        let localRotationsEulerXYZ: [String: SIMD3<Float>]
        let projectionErrors: [String: Float]
        let solvedJoints: Set<String>
        let missingJoints: Set<String>
        let bodyBasis: RotoBodyBasis
    }
}
