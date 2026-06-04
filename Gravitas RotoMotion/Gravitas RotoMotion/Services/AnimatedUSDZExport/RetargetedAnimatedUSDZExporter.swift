import Foundation

enum RetargetedAnimatedUSDZExporter {
    static func exportAnimatedTargetUSDZ(
        targetUSDZ: URL,
        solve: RotoRayAnimationSolveResult,
        clipID: String,
        includeHipsTranslation: Bool,
        rootTranslationScale: Double,
        pythonExecutablePath: String,
        outputDirectory: URL
    ) throws -> URL {
        let safeClipID = sanitizeFileName(clipID)
        let workDir = outputDirectory
            .appendingPathComponent("\(safeClipID)_target_usdz_work", isDirectory: true)
        let solvedJSON = workDir.appendingPathComponent("\(safeClipID)_solved_animation.json")
        let scriptURL = workDir.appendingPathComponent("rotomotion_usdz_retarget.py")
        let outputUSDZ = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_target.usdz")

        if FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        try SolvedAnimationJSONExporter.write(
            solve: solve,
            includeHipsTranslation: includeHipsTranslation,
            to: solvedJSON
        )

        try RotoMotionUSDZRetargetPythonScript.contents.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )

        let result = run(
            executable: pythonExecutablePath,
            arguments: [
                scriptURL.path,
                "--target-usdz",
                targetUSDZ.path,
                "--solved-json",
                solvedJSON.path,
                "--clip-id",
                clipID,
                "--work-dir",
                workDir.path,
                "--output-usdz",
                outputUSDZ.path,
                "--root-translation-scale",
                String(format: "%.8f", rootTranslationScale)
            ] + (includeHipsTranslation ? ["--include-hips-translation"] : [])
        )

        if result.exitCode != 0 {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8201,
                userInfo: [
                    NSLocalizedDescriptionKey:
                    """
                    Animated target USDZ export failed.

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
                code: 8202,
                userInfo: [
                    NSLocalizedDescriptionKey: "Animated target USDZ export finished but output file is missing: \(outputUSDZ.path)"
                ]
            )
        }

        return outputUSDZ
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

        return sanitized.isEmpty ? "rotomotion_retarget" : sanitized
    }
}
