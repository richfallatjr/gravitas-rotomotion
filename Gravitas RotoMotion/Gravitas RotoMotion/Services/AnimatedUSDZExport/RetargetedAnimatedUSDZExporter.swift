import Foundation

enum RetargetedAnimatedUSDZExporter {
    struct ExportResult {
        let outputUSDZ: URL
        let workDirectory: URL
        let raySolveReferenceJSON: URL
        let exportInputJSON: URL
        let readbackJSON: URL
        let auditTextReport: URL
        let auditJSONReport: URL
        let auditIssueCount: Int
        let auditHighSeverityCount: Int
    }

    static func exportAnimatedTargetUSDZ(
        targetUSDZ: URL,
        solve: RotoRayAnimationSolveResult,
        clipID: String,
        includeHipsTranslation: Bool,
        rootTranslationScale: Double,
        pythonExecutablePath: String,
        outputDirectory: URL
    ) throws -> ExportResult {
        let safeClipID = sanitizeFileName(clipID)
        let outputUSDZ = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_target.usdz")
        let workDir = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_usdz_work", isDirectory: true)
        let raySolveReferenceJSON = workDir.appendingPathComponent("ray_solve_reference.json")
        let exportInputJSON = workDir.appendingPathComponent("animated_usdz_export_input.json")
        let readbackJSON = workDir.appendingPathComponent("animated_usdz_readback.json")
        let auditTextReport = workDir.appendingPathComponent("export_audit_report.txt")
        let auditJSONReport = workDir.appendingPathComponent("export_audit_report.json")
        let scriptURL = workDir.appendingPathComponent("rotomotion_usdz_retarget.py")

        if FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }

        if FileManager.default.fileExists(atPath: outputUSDZ.path) {
            try FileManager.default.removeItem(at: outputUSDZ)
        }

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        try RaySolveReferenceJSONExporter.write(
            solve: solve,
            to: raySolveReferenceJSON
        )

        try SolvedAnimationJSONExporter.write(
            solve: solve,
            includeHipsTranslation: includeHipsTranslation,
            to: exportInputJSON
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
                exportInputJSON.path,
                "--ray-solve-reference",
                raySolveReferenceJSON.path,
                "--clip-id",
                clipID,
                "--work-dir",
                workDir.path,
                "--output-usdz",
                outputUSDZ.path,
                "--readback-json",
                readbackJSON.path,
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

        let outputAttributes = try FileManager.default.attributesOfItem(
            atPath: outputUSDZ.path
        )

        let outputSize = (outputAttributes[.size] as? NSNumber)?.int64Value ?? 0

        guard outputSize > 0 else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8203,
                userInfo: [
                    NSLocalizedDescriptionKey: "Animated target USDZ export created an empty file: \(outputUSDZ.path)"
                ]
            )
        }

        let audit: RotoMotionExportKeyAuditor.Output

        do {
            audit = try RotoMotionExportKeyAuditor.writeAudit(
                solve: solve,
                exportInputURL: exportInputJSON,
                readbackURL: readbackJSON,
                textReportURL: auditTextReport,
                jsonReportURL: auditJSONReport
            )
        } catch {
            let message = """
            RotoMotion Export Key Audit

            Audit failed, but the animated USDZ was created:
            \(outputUSDZ.path)

            Error:
            \(error.localizedDescription)
            """

            try? message.write(
                to: auditTextReport,
                atomically: true,
                encoding: .utf8
            )

            let json: [String: Any] = [
                "schema": "com.gravitas.rotomotion.export_audit.v0",
                "auditFailed": true,
                "outputUSDZ": outputUSDZ.path,
                "error": error.localizedDescription
            ]

            if let data = try? JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: auditJSONReport, options: .atomic)
            }

            audit = .init(
                issueCount: 1,
                highSeverityCount: 1
            )
        }

        return ExportResult(
            outputUSDZ: outputUSDZ,
            workDirectory: workDir,
            raySolveReferenceJSON: raySolveReferenceJSON,
            exportInputJSON: exportInputJSON,
            readbackJSON: readbackJSON,
            auditTextReport: auditTextReport,
            auditJSONReport: auditJSONReport,
            auditIssueCount: audit.issueCount,
            auditHighSeverityCount: audit.highSeverityCount
        )
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
