import CoreGraphics
import CoreVideo
import Foundation
import Vision

final class VisionPoseExtractor {
    func extractPose(
        from pixelBuffer: CVPixelBuffer
    ) throws -> [String: RawVisionPoseCapture.JointObservation] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        try handler.perform([request])

        guard let observation = request.results?.first else {
            return [:]
        }

        let recognized = try observation.recognizedPoints(.all)
        var output: [String: RawVisionPoseCapture.JointObservation] = [:]

        for (jointName, point) in recognized where point.confidence > 0 {
            output[jointName.rawValue.rawValue] = RawVisionPoseCapture.JointObservation(
                x: Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }

        return output
    }
}
