import Foundation

enum USDZPackager {
    static func packageUSDAAsUSDZ(
        usdaURL: URL,
        usdzURL: URL
    ) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: usdzURL.path) {
            try fileManager.removeItem(at: usdzURL)
        }

        if let usdzipPath = findUSDZipPath() {
            try runPackageCommand(
                executableURL: URL(fileURLWithPath: usdzipPath),
                currentDirectoryURL: usdaURL.deletingLastPathComponent(),
                arguments: [
                    usdzURL.path,
                    usdaURL.lastPathComponent
                ]
            )
            return
        }

        // Fallback for local preview. usdzip is preferred for Blender/OpenUSD.
        try runPackageCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            currentDirectoryURL: usdaURL.deletingLastPathComponent(),
            arguments: [
                "-0",
                "-X",
                usdzURL.path,
                usdaURL.lastPathComponent
            ]
        )
    }

    private static func runPackageCommand(
        executableURL: URL,
        currentDirectoryURL: URL,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = currentDirectoryURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown zip error"

            throw NSError(
                domain: "GravitasRotoMotion",
                code: 3001,
                userInfo: [NSLocalizedDescriptionKey: "USDZ packaging failed: \(message)"]
            )
        }
    }

    private static func findUSDZipPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "usdzip"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
