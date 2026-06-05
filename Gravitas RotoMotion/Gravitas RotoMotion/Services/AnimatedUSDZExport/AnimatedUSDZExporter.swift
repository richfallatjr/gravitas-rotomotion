import Foundation

enum AnimatedUSDZExporter {
    static func exportAnimatedUSDZ(
        sourceUSDZ: URL,
        clipID: String,
        normalized: NormalizedMeshyPoseCapture?,
        smoothed: SmoothedMeshyPoseCapture?,
        fitResult: RigFitResult?,
        pythonExecutablePath: String,
        outputDirectory: URL
    ) throws -> URL {
        let safeClipID = sanitizeFileName(clipID)

        let workDir = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_usdz_work", isDirectory: true)

        let outputUSDZ = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated.usdz")

        if FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        let scriptURL = try writePythonScript(to: workDir)
        let keyframesJSON = try writeMemoryKeyframesJSON(
            normalized: normalized,
            smoothed: smoothed,
            fitResult: fitResult,
            to: workDir
        )

        let result = run(
            executable: pythonExecutablePath,
            arguments: [
                scriptURL.path,
                "--source-usdz",
                sourceUSDZ.path,
                "--keyframes",
                keyframesJSON.path,
                "--clip-id",
                clipID,
                "--work-dir",
                workDir.path,
                "--output-usdz",
                outputUSDZ.path
            ]
        )

        if result.exitCode != 0 {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                        Animated USDZ export failed.
                        STDOUT:
                        \(result.stdout)

                        STDERR:
                        \(result.stderr)
                        """
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: outputUSDZ.path) else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8002,
                userInfo: [
                    NSLocalizedDescriptionKey: "Animated USDZ export finished but output file is missing: \(outputUSDZ.path)"
                ]
            )
        }

        print(
            """
            [RotoMotion AnimatedUSDZ] Export complete
              output: \(outputUSDZ.path)
              stdout: \(result.stdout)
            """
        )

        return outputUSDZ
    }

    private static func writeMemoryKeyframesJSON(
        normalized: NormalizedMeshyPoseCapture?,
        smoothed: SmoothedMeshyPoseCapture?,
        fitResult: RigFitResult?,
        to directory: URL
    ) throws -> URL {
        let object: [String: [[Any]]]

        if let fitResult,
           !fitResult.frames.isEmpty {
            object = keyframesFromFitResult(fitResult)
        } else if let smoothed {
            object = keyframesFromSmoothed(smoothed)
        } else if let normalized {
            object = keyframesFromNormalized(normalized)
        } else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8003,
                userInfo: [
                    NSLocalizedDescriptionKey: "No in-memory normalized or smoothed capture available for animated USDZ export."
                ]
            )
        }

        let url = directory.appendingPathComponent("rotomotion_memory_keyframes.json")
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: url, options: .atomic)
        return url
    }

    private static func keyframesFromNormalized(
        _ normalized: NormalizedMeshyPoseCapture
    ) -> [String: [[Any]]] {
        var output: [String: [[Any]]] = [:]
        let frames = normalized.frames

        guard !frames.isEmpty else {
            return output
        }

        for jointName in CanonicalRig.jointNames {
            let keys: [[Any]] = frames.compactMap { frame in
                guard let joint = frame.joints[jointName], !joint.missing else {
                    return nil
                }

                // The Python authoring step interprets these as normalized
                // marker targets, then solves source-length local translations
                // scaled to a 1.74 m Meshy character.
                return [
                    frame.frameIndex,
                    joint.x,
                    0.0,
                    joint.y,
                    0.0,
                    0.0,
                    0.0,
                    "linear"
                ]
            }

            if !keys.isEmpty {
                output[jointName] = keys
            }
        }

        return output
    }

    private static func keyframesFromSmoothed(
        _ smoothed: SmoothedMeshyPoseCapture
    ) -> [String: [[Any]]] {
        var output: [String: [[Any]]] = [:]
        let frames = smoothed.frames

        guard !frames.isEmpty else {
            return output
        }

        for jointName in CanonicalRig.jointNames {
            let keys: [[Any]] = frames.compactMap { frame in
                guard let joint = frame.joints[jointName], !joint.missing else {
                    return nil
                }

                return [
                    frame.frameIndex,
                    joint.smoothedX,
                    0.0,
                    joint.smoothedY,
                    0.0,
                    0.0,
                    0.0,
                    "linear"
                ]
            }

            if !keys.isEmpty {
                output[jointName] = keys
            }
        }

        return output
    }

    private static func keyframesFromFitResult(
        _ fitResult: RigFitResult
    ) -> [String: [[Any]]] {
        var output: [String: [[Any]]] = [:]

        for jointName in CanonicalRig.jointNames {
            let keys: [[Any]] = fitResult.frames.compactMap { frame in
                guard let rotation = frame.localRotationsEulerXYZ[jointName] else {
                    return nil
                }

                return [
                    frame.frameIndex,
                    0.0,
                    0.0,
                    0.0,
                    rotation.x,
                    rotation.y,
                    rotation.z,
                    "linear"
                ]
            }

            if !keys.isEmpty {
                output[jointName] = keys
            }
        }

        return output
    }

    private static func writePythonScript(to directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("rotomotion_usdz_animator.py")

        try RotoMotionUSDZAnimatorPythonScript.contents.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )

        return scriptURL
    }

    private static func run(
        executable: String,
        arguments: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()

        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            return (
                process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    private static func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)

        let sanitized = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")

        return sanitized.isEmpty ? "rotomotion_animated" : sanitized
    }
}
