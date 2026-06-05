import CoreGraphics
import CoreMedia
import Foundation

enum StereoEye: String, Codable {
    case left
    case right
}

struct SpatialEyeFrameDiagnostic: Codable, Identifiable {
    var id: String { "\(eye.rawValue)_\(frameIndex)" }

    let eye: StereoEye
    let frameIndex: Int
    let presentationTimeSeconds: Double

    let layerIDs: [Int]
    let viewIDs: [Int]

    let pixelWidth: Int
    let pixelHeight: Int
    let pixelFormat: String

    let ciExtentX: Double
    let ciExtentY: Double
    let ciExtentWidth: Double
    let ciExtentHeight: Double

    let cgImageWidth: Int
    let cgImageHeight: Int

    let preferredTransformA: Double
    let preferredTransformB: Double
    let preferredTransformC: Double
    let preferredTransformD: Double
    let preferredTransformTX: Double
    let preferredTransformTY: Double

    let cleanApertureWidth: Double?
    let cleanApertureHeight: Double?

    let pngPath: String?
}

struct SpatialDecodedEyeFrame {
    let eye: StereoEye
    let frameIndex: Int
    let presentationTime: CMTime
    let cgImage: CGImage
    let diagnostic: SpatialEyeFrameDiagnostic
}

struct SpatialStereoDecodeResult {
    let leftFrames: [SpatialDecodedEyeFrame]
    let rightFrames: [SpatialDecodedEyeFrame]
    let diagnostics: [SpatialEyeFrameDiagnostic]
    let dumpDirectory: URL
}
