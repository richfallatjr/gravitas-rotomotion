import AppKit
import CoreGraphics
import CoreImage
import Foundation

enum SpatialEyeImageConverterError: Error {
    case failedToCreateCGImage
}

final class SpatialEyeImageConverter {
    private let ciContext = CIContext(options: nil)

    func makeCGImage(
        from pixelBuffer: CVPixelBuffer,
        preferredTransform: CGAffineTransform
    ) throws -> (cgImage: CGImage, ciExtent: CGRect) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Same transform path for both eyes. Do not special-case either eye here.
        let transformed = ciImage.transformed(by: preferredTransform)
        let extent = transformed.extent.integral

        guard let cgImage = ciContext.createCGImage(transformed, from: extent) else {
            throw SpatialEyeImageConverterError.failedToCreateCGImage
        }

        return (cgImage, extent)
    }
}
