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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = usdaURL.deletingLastPathComponent()
        process.arguments = [
            "-0",
            "-X",
            usdzURL.path,
            usdaURL.lastPathComponent
        ]

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
}
