import AVFoundation
import Foundation

enum SpatialVideoMetadataReader {
    static func readMetadata(url: URL) async throws -> SpatialVideoCameraMetadata {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7201,
                userInfo: [NSLocalizedDescriptionKey: "Spatial video has no video track."]
            )
        }

        let naturalSize = try await track.load(.naturalSize)

        let width = max(Int(abs(naturalSize.width).rounded()), 1)
        let height = max(Int(abs(naturalSize.height).rounded()), 1)
        let formatDescriptions = try await track.load(.formatDescriptions)

        var horizontalFOVDegrees: Double?
        var verticalFOVDegrees: Double?
        var baselineMeters: Double?
        var disparityAdjustment: Double?
        var metadataLines: [String] = []

        for (index, formatDescription) in formatDescriptions.enumerated() {
            let parsed = parseSpatialMetadata(from: formatDescription)

            horizontalFOVDegrees = horizontalFOVDegrees ?? parsed.horizontalFOVDegrees
            verticalFOVDegrees = verticalFOVDegrees ?? parsed.verticalFOVDegrees
            baselineMeters = baselineMeters ?? parsed.baselineMeters
            disparityAdjustment = disparityAdjustment ?? parsed.disparityAdjustment

            metadataLines.append(
                """
                format \(index):
                  HorizontalFieldOfView: \(parsed.rawHorizontalFOV.map { "\($0)" } ?? "nil") -> \(parsed.horizontalFOVDegrees.map { "\($0)" } ?? "nil")
                  VerticalFieldOfView: \(parsed.rawVerticalFOV.map { "\($0)" } ?? "nil") -> \(parsed.verticalFOVDegrees.map { "\($0)" } ?? "nil")
                  StereoCameraBaseline: \(parsed.rawBaseline.map { "\($0)" } ?? "nil") -> \(parsed.baselineMeters.map { "\($0)" } ?? "nil")
                  HorizontalDisparityAdjustment: \(parsed.rawDisparityAdjustment.map { "\($0)" } ?? "nil") -> \(parsed.disparityAdjustment.map { "\($0)" } ?? "nil")
                """
            )
        }

        let metadata = SpatialVideoCameraMetadata(
            baselineMeters: baselineMeters,
            horizontalFOVDegrees: horizontalFOVDegrees,
            verticalFOVDegrees: verticalFOVDegrees,
            disparityAdjustment: disparityAdjustment,
            imageWidth: width,
            imageHeight: height
        )

        print(
            """
            [SpatialVideoMetadata] video track metadata:
              imageSize: \(width)x\(height)
              baselineMeters: \(baselineMeters.map { "\($0)" } ?? "nil")
              horizontalFOVDegrees: \(horizontalFOVDegrees.map { "\($0)" } ?? "nil")
              verticalFOVDegrees: \(verticalFOVDegrees.map { "\($0)" } ?? "nil")
              disparityAdjustment: \(disparityAdjustment.map { "\($0)" } ?? "nil")
              parsed format metadata:
            \(metadataLines.joined(separator: "\n"))
            """
        )

        return metadata
    }

    private struct ParsedSpatialMetadata {
        var rawHorizontalFOV: Double?
        var rawVerticalFOV: Double?
        var rawBaseline: Double?
        var rawDisparityAdjustment: Double?

        var horizontalFOVDegrees: Double?
        var verticalFOVDegrees: Double?
        var baselineMeters: Double?
        var disparityAdjustment: Double?
    }

    private static func parseSpatialMetadata(
        from formatDescription: CMFormatDescription
    ) -> ParsedSpatialMetadata {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return ParsedSpatialMetadata()
        }

        var parsed = ParsedSpatialMetadata()

        func scan(_ value: Any, path: String) {
            let pathLower = path.lowercased()

            if parsed.rawHorizontalFOV == nil,
               (pathLower.contains("horizontalfieldofview") ||
                (pathLower.contains("horizontal") && pathLower.contains("fov"))) {
                parsed.rawHorizontalFOV = numericDouble(value)
                parsed.horizontalFOVDegrees = parseFOVDegrees(parsed.rawHorizontalFOV)
            }

            if parsed.rawVerticalFOV == nil,
               (pathLower.contains("verticalfieldofview") ||
                (pathLower.contains("vertical") && pathLower.contains("fov"))) {
                parsed.rawVerticalFOV = numericDouble(value)
                parsed.verticalFOVDegrees = parseFOVDegrees(parsed.rawVerticalFOV)
            }

            if parsed.rawBaseline == nil,
               pathLower.contains("baseline") {
                parsed.rawBaseline = numericDouble(value)
                parsed.baselineMeters = parseBaselineMeters(parsed.rawBaseline)
            }

            if parsed.rawDisparityAdjustment == nil,
               pathLower.contains("disparity") {
                parsed.rawDisparityAdjustment = numericDouble(value)
                parsed.disparityAdjustment = parsed.rawDisparityAdjustment
            }

            if let dictionary = value as? NSDictionary {
                for (key, item) in dictionary {
                    scan(item, path: "\(path).\(String(describing: key))")
                }
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, item) in dictionary {
                    scan(item, path: "\(path).\(key)")
                }
                return
            }

            if let array = value as? NSArray {
                for (index, item) in array.enumerated() {
                    scan(item, path: "\(path)[\(index)]")
                }
                return
            }

            if let array = value as? [Any] {
                for (index, item) in array.enumerated() {
                    scan(item, path: "\(path)[\(index)]")
                }
            }
        }

        scan(extensions, path: "extensions")
        return parsed
    }

    private static func parseFOVDegrees(
        _ raw: Double?
    ) -> Double? {
        guard let value = raw else { return nil }

        if value > 360 {
            return value / 1000.0
        }

        return value
    }

    private static func parseBaselineMeters(
        _ raw: Double?
    ) -> Double? {
        guard let value = raw else { return nil }

        if value > 1000 {
            return value / 1_000_000.0
        }

        if value > 1 {
            return value / 1000.0
        }

        return value
    }

    private static func numericDouble(
        _ value: Any
    ) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let double = value as? Double {
            return double
        }

        if let float = value as? Float {
            return Double(float)
        }

        if let int = value as? Int {
            return Double(int)
        }

        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}
