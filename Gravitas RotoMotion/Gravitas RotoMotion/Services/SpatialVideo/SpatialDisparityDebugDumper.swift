import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SpatialDisparityDebugStats {
    let totalPixels: Int
    let validDepthPixels: Int
    let validPercent: Double
    let minDepthMeters: Double
    let medianDepthMeters: Double
    let maxDepthMeters: Double

    static func make(frame: SpatialDisparityMapCapture.Frame) -> SpatialDisparityDebugStats {
        let values = frame.depthMeters
            .filter { $0.isFinite && $0 > 0 }
            .map(Double.init)
            .sorted()

        let total = frame.width * frame.height
        let valid = values.count

        guard !values.isEmpty else {
            return SpatialDisparityDebugStats(
                totalPixels: total,
                validDepthPixels: 0,
                validPercent: 0,
                minDepthMeters: 0,
                medianDepthMeters: 0,
                maxDepthMeters: 0
            )
        }

        return SpatialDisparityDebugStats(
            totalPixels: total,
            validDepthPixels: valid,
            validPercent: Double(valid) / Double(max(total, 1)) * 100.0,
            minDepthMeters: values.first ?? 0,
            medianDepthMeters: values[values.count / 2],
            maxDepthMeters: values.last ?? 0
        )
    }
}

struct SpatialDisparityDebugDump {
    let directory: URL
    let depthImage: NSImage?
    let confidenceImage: NSImage?
    let rawDisparityImage: NSImage?
}

enum SpatialDisparityDebugDumper {
    static func dumpDebugImages(
        frame: SpatialDisparityMapCapture.Frame
    ) throws -> SpatialDisparityDebugDump {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotomotion_disparity_debug_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let depthCG = try makeDepthPreviewCGImage(frame: frame)
        let confidenceCG = try makeConfidencePreviewCGImage(frame: frame)
        let rawCG = try makeRawDisparityPreviewCGImage(frame: frame)

        try writePNG(depthCG, to: directory.appendingPathComponent("depth_preview.png"))
        try writePNG(confidenceCG, to: directory.appendingPathComponent("confidence_preview.png"))
        try writePNG(rawCG, to: directory.appendingPathComponent("raw_disparity_preview.png"))

        return SpatialDisparityDebugDump(
            directory: directory,
            depthImage: NSImage(
                cgImage: depthCG,
                size: NSSize(width: frame.width, height: frame.height)
            ),
            confidenceImage: NSImage(
                cgImage: confidenceCG,
                size: NSSize(width: frame.width, height: frame.height)
            ),
            rawDisparityImage: NSImage(
                cgImage: rawCG,
                size: NSSize(width: frame.width, height: frame.height)
            )
        )
    }

    static func makeDepthPreviewCGImage(
        frame: SpatialDisparityMapCapture.Frame
    ) throws -> CGImage {
        let finite = frame.depthMeters.filter { $0.isFinite && $0 > 0 }

        guard let minDepth = finite.min(),
              let maxDepth = finite.max(),
              maxDepth > minDepth else {
            return try makeGrayscaleImage(
                width: frame.width,
                height: frame.height,
                pixels: [UInt8](repeating: 0, count: frame.width * frame.height)
            )
        }

        var pixels = [UInt8](repeating: 0, count: frame.width * frame.height)

        for i in 0..<pixels.count {
            let depth = frame.depthMeters[i]

            if depth.isFinite && depth > 0 {
                let normalized = 1.0 - max(0.0, min(1.0, (depth - minDepth) / (maxDepth - minDepth)))
                pixels[i] = UInt8(normalized * 255.0)
            }
        }

        return try makeGrayscaleImage(
            width: frame.width,
            height: frame.height,
            pixels: pixels
        )
    }

    static func makeConfidencePreviewCGImage(
        frame: SpatialDisparityMapCapture.Frame
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: frame.width * frame.height)

        for i in 0..<pixels.count {
            let confidence = max(0, min(1, frame.confidence[i]))
            pixels[i] = UInt8(confidence * 255)
        }

        return try makeGrayscaleImage(
            width: frame.width,
            height: frame.height,
            pixels: pixels
        )
    }

    static func makeRawDisparityPreviewCGImage(
        frame: SpatialDisparityMapCapture.Frame
    ) throws -> CGImage {
        let finite = frame.disparityPixels.filter { $0.isFinite }

        guard let minDisparity = finite.min(),
              let maxDisparity = finite.max(),
              maxDisparity > minDisparity else {
            return try makeGrayscaleImage(
                width: frame.width,
                height: frame.height,
                pixels: [UInt8](repeating: 0, count: frame.width * frame.height)
            )
        }

        var pixels = [UInt8](repeating: 0, count: frame.width * frame.height)

        for i in 0..<pixels.count {
            let disparity = frame.disparityPixels[i]

            if disparity.isFinite {
                let normalized = max(0, min(1, (disparity - minDisparity) / (maxDisparity - minDisparity)))
                pixels[i] = UInt8(normalized * 255)
            }
        }

        return try makeGrayscaleImage(
            width: frame.width,
            height: frame.height,
            pixels: pixels
        )
    }

    private static func makeGrayscaleImage(
        width: Int,
        height: Int,
        pixels: [UInt8]
    ) throws -> CGImage {
        guard pixels.count == width * height else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 102,
                userInfo: [
                    NSLocalizedDescriptionKey: "Disparity preview pixel count does not match image size."
                ]
            )
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 103,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create disparity preview image."
                ]
            )
        }

        return image
    }

    static func writePNG(
        _ image: CGImage,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 100,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create PNG destination."
                ]
            )
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 101,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to finalize PNG."
                ]
            )
        }
    }
}
