import Foundation

struct SessionArmaturePoseBuffer: Codable {
    let schema: String
    let clipID: String
    let fps: Double
    let frames: [Frame]

    struct Frame: Codable {
        let frameIndex: Int
        let timeSeconds: Double
        let joints: [String: JointTransform]
    }

    struct JointTransform: Codable {
        let localTranslationXYZ: [Double]
        let localRotationEulerXYZ: [Double]
        let localScaleXYZ: [Double]
    }
}
