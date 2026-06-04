import Foundation

enum USDZSkeletonInspector {
    static func inspectUSDZ(
        _ url: URL,
        pythonExecutablePath: String
    ) throws -> USDZSkeletonProfile {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotomotion_usdz_inspect_\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        let scriptURL = try writeInspectorScript(to: workDir)
        let outputURL = workDir.appendingPathComponent("skeleton_profile.json")

        let result = run(
            executable: pythonExecutablePath,
            arguments: [
                scriptURL.path,
                "--source-usdz",
                url.path,
                "--output-json",
                outputURL.path
            ]
        )

        if result.exitCode != 0 {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8101,
                userInfo: [
                    NSLocalizedDescriptionKey:
                    """
                    USDZ skeleton inspection failed.

                    STDOUT:
                    \(result.stdout)

                    STDERR:
                    \(result.stderr)
                    """
                ]
            )
        }

        let data = try Data(contentsOf: outputURL)
        return try JSONDecoder().decode(USDZSkeletonProfile.self, from: data)
    }

    private static func writeInspectorScript(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("rotomotion_usdz_inspector.py")

        try RotoMotionUSDZInspectorPythonScript.contents.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        return url
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
}
