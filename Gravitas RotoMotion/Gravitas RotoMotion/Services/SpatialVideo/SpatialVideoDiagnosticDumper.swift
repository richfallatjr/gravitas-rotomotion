import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class SpatialVideoDiagnosticDumper {
    func makeDumpDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rotomotion_spatial_diag_\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )

        return base
    }

    func writePNG(
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
                domain: "RotoMotion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination."]
            )
        }

        CGImageDestinationAddImage(destination, image, nil)

        if !CGImageDestinationFinalize(destination) {
            throw NSError(
                domain: "RotoMotion",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG destination."]
            )
        }
    }
}
