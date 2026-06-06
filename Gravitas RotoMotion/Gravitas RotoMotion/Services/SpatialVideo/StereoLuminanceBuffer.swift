import CoreGraphics
import Foundation

struct StereoLuminanceBuffer {
    let width: Int
    let height: Int
    let pixels: [Float]
}

enum StereoLuminanceConverter {
    static func makeLuminanceBuffer(
        from cgImage: CGImage,
        scale: Double
    ) throws -> StereoLuminanceBuffer {
        let clampedScale = max(0.02, min(scale, 1.0))
        let targetWidth = max(2, Int(Double(cgImage.width) * clampedScale))
        let targetHeight = max(2, Int(Double(cgImage.height) * clampedScale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var rgba = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)

        guard let context = CGContext(
            data: &rgba,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create luminance CGContext."
                ]
            )
        }

        context.interpolationQuality = .medium
        context.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: targetWidth,
                height: targetHeight
            )
        )

        var out = [Float](repeating: 0, count: targetWidth * targetHeight)

        for i in 0..<(targetWidth * targetHeight) {
            let r = Float(rgba[i * 4]) / 255.0
            let g = Float(rgba[i * 4 + 1]) / 255.0
            let b = Float(rgba[i * 4 + 2]) / 255.0

            out[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        return StereoLuminanceBuffer(
            width: targetWidth,
            height: targetHeight,
            pixels: out
        )
    }
}
