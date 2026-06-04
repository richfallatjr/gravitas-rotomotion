import Foundation

struct OpenUSDToolStatus: Equatable {
    let pythonOK: Bool
    let usdzipOK: Bool
    let pythonExecutablePath: String?
    let pythonMessage: String
    let usdzipPath: String?

    var ready: Bool {
        pythonOK && usdzipOK
    }
}

enum OpenUSDToolChecker {
    static func check() -> OpenUSDToolStatus {
        let python = firstOpenUSDPython()

        let usdzip = run(
            executable: "/usr/bin/env",
            arguments: [
                "which",
                "usdzip"
            ]
        )

        let usdzipPath = usdzip.exitCode == 0
            ? usdzip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        return OpenUSDToolStatus(
            pythonOK: python.executablePath != nil,
            usdzipOK: usdzip.exitCode == 0,
            pythonExecutablePath: python.executablePath,
            pythonMessage: python.message,
            usdzipPath: usdzipPath
        )
    }

    private static func firstOpenUSDPython() -> (executablePath: String?, message: String) {
        var failures: [String] = []

        for executablePath in candidatePythonExecutables() {
            let result = run(
                executable: executablePath,
                arguments: [
                    "-c",
                    "from pxr import Usd, UsdSkel, Sdf, Gf; print('OpenUSD Python OK')"
                ]
            )

            if result.exitCode == 0 {
                return (
                    executablePath,
                    "\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) (\(executablePath))"
                )
            }

            let failureMessage = result.stderr.isEmpty ? result.stdout : result.stderr
            failures.append("\(executablePath): \(failureMessage.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return (
            nil,
            failures.isEmpty
                ? "No Python executables found to check for OpenUSD pxr."
                : failures.joined(separator: "\n")
        )
    }

    private static func candidatePythonExecutables() -> [String] {
        var paths: [String] = []

        if let override = ProcessInfo.processInfo.environment["ROTOMOTION_USD_PYTHON"],
           !override.isEmpty {
            paths.append(override)
        }

        paths.append(contentsOf: [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ])

        paths.append(contentsOf: blenderPythonExecutables())

        var seen = Set<String>()

        return paths.filter { path in
            guard !seen.contains(path),
                  FileManager.default.isExecutableFile(atPath: path) else {
                return false
            }

            seen.insert(path)
            return true
        }
    }

    private static func blenderPythonExecutables() -> [String] {
        let resourcesURL = URL(
            fileURLWithPath: "/Applications/Blender.app/Contents/Resources",
            isDirectory: true
        )

        guard let enumerator = FileManager.default.enumerator(
            at: resourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("python3"),
                  url.path.contains("/python/bin/"),
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                continue
            }

            paths.append(url.path)
        }

        return paths.sorted()
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
