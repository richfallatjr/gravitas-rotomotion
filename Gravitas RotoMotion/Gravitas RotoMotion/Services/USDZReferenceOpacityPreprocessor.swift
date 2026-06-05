import Foundation

enum USDZReferenceOpacityPreprocessor {
    static func makeTransparentReferenceUSDZ(
        sourceUSDZ: URL,
        opacity: Double,
        workDirectory: URL,
        pythonExecutablePath: String
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )

        let scriptURL = workDirectory.appendingPathComponent("make_usdz_transparent.py")
        try RotoMotionUSDZOpacityPythonScript.contents.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )

        let outputURL = workDirectory.appendingPathComponent(
            sourceUSDZ.deletingPathExtension().lastPathComponent + "_opacity50.usdz"
        )

        let result = run(
            executable: pythonExecutablePath,
            arguments: [
                scriptURL.path,
                "--source-usdz",
                sourceUSDZ.path,
                "--output-usdz",
                outputURL.path,
                "--opacity",
                String(opacity)
            ]
        )

        if result.exitCode != 0 {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 12001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                    """
                    USDZ opacity preprocessing failed.

                    STDOUT:
                    \(result.stdout)

                    STDERR:
                    \(result.stderr)
                    """
                ]
            )
        }

        print(
            """
            [USDZReferenceOpacityPreprocessor] Created transparent reference USDZ
              source: \(sourceUSDZ.path)
              output: \(outputURL.path)
              opacity: \(opacity)
              stdout:
            \(result.stdout)
            """
        )

        return outputURL
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

            return (
                process.terminationStatus,
                String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}
