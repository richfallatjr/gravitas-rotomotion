import Foundation

enum RotoMotionPreviewPackageExporter {
    static func exportPackage(
        sourceCharacterUSDZ: URL,
        clipID: String,
        displayName: String,
        videoURL: URL?,
        normalized: NormalizedMeshyPoseCapture?,
        smoothed: SmoothedMeshyPoseCapture?,
        rawCapture: RawVisionPoseCapture?,
        outputDirectory: URL
    ) throws -> URL {
        let safeClipID = sanitizeFileName(clipID)
        let packageDir = outputDirectory
            .appendingPathComponent(safeClipID, isDirectory: true)

        try FileManager.default.createDirectory(
            at: packageDir,
            withIntermediateDirectories: true
        )

        let characterDest = packageDir.appendingPathComponent("character.usdz")
        let jockAnimFileName = "\(safeClipID).jockanim.json"
        let jockAnimDest = packageDir.appendingPathComponent(jockAnimFileName)
        let packageManifestDest = packageDir.appendingPathComponent("preview_package.json")
        let libraryManifestDest = packageDir.appendingPathComponent("manifest.json")

        if FileManager.default.fileExists(atPath: characterDest.path) {
            try FileManager.default.removeItem(at: characterDest)
        }

        try FileManager.default.copyItem(
            at: sourceCharacterUSDZ,
            to: characterDest
        )

        let fps = inferFPS(
            normalized: normalized,
            smoothed: smoothed
        )

        let payload = try RotoMotionJockAnimExporter.makeJockAnimPayload(
            clipID: clipID,
            displayName: displayName,
            normalized: normalized,
            smoothed: smoothed,
            fps: fps
        )

        try writeJSONObject(payload, to: jockAnimDest)

        let duration = ((payload["timing"] as? [String: Any])?["duration_seconds"] as? Double) ?? 0
        let frameCount = smoothed?.frames.count ?? normalized?.frames.count ?? 0

        let package = RotoMotionPreviewPackage(
            schema: "com.gravitas.rotomotion.preview_package.v0",
            packageID: safeClipID,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
            sourceCharacter: .init(
                originalFileName: sourceCharacterUSDZ.lastPathComponent,
                bundledFileName: "character.usdz",
                role: "static_character_rig_model_weights_materials"
            ),
            animation: .init(
                clipID: clipID,
                displayName: displayName,
                jockAnimFileName: jockAnimFileName,
                rigID: CanonicalRig.rigID,
                rigVersion: CanonicalRig.rigVersion,
                fps: fps,
                frameCount: frameCount,
                durationSeconds: duration
            ),
            provenance: .init(
                appName: "Gravitas RotoMotion",
                appVersion: "0.1",
                sourceVideoFileName: videoURL?.lastPathComponent,
                sourceVideoPath: videoURL?.path,
                visionFrames: rawCapture?.frames.count ?? 0,
                normalizedFrames: normalized?.frames.count ?? 0,
                smoothedFrames: smoothed?.frames.count ?? 0,
                notes: "Preview package. Static USDZ plus JockAnim sidecar. No animated USDZ baking."
            )
        )

        try JSONCoding.writePretty(package, to: packageManifestDest)

        let miniManifest: [String: Any] = [
            "schema": "com.gravitas.rotomotion.package_manifest.v0",
            "clips": [
                [
                    "clip_id": clipID,
                    "display_name": displayName,
                    "relative_path": jockAnimFileName,
                    "character_usdz": "character.usdz",
                    "rig_id": CanonicalRig.rigID,
                    "rig_version": CanonicalRig.rigVersion
                ]
            ]
        ]

        try writeJSONObject(miniManifest, to: libraryManifestDest)

        return packageDir
    }

    private static func inferFPS(
        normalized: NormalizedMeshyPoseCapture?,
        smoothed: SmoothedMeshyPoseCapture?
    ) -> Double {
        let frames = smoothed?.frames.map { ($0.frameIndex, $0.timeSeconds) }
            ?? normalized?.frames.map { ($0.frameIndex, $0.timeSeconds) }
            ?? []

        guard frames.count > 1,
              let first = frames.first,
              let last = frames.last else {
            return 24.0
        }

        let duration = max(last.1 - first.1, 0.0001)
        return Double(frames.count - 1) / duration
    }

    private static func writeJSONObject(
        _ object: Any,
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: url, options: .atomic)
    }

    private static func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)

        return value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
