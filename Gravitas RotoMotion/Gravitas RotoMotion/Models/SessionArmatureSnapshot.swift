import Foundation
import simd

struct SessionArmatureSnapshot: Equatable {
    let schema: String
    let sourceKind: String
    let rigID: String
    let rigVersion: String
    let frameCount: Int
    let fps: Double
    let frames: [Frame]

    struct Frame: Equatable, Identifiable {
        var id: Int { frameIndex }

        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: JointTransform]
    }

    struct JointTransform: Equatable {
        let jointName: String
        let localTranslation: SIMD3<Float>
        let localRotationWXYZ: SIMD4<Float>
        let localScale: SIMD3<Float>
    }
}
