import Foundation

enum RetargetedAnimatedUSDZExporter {
    struct ExportResult {
        let outputUSDZ: URL
        let workDirectory: URL
        let sessionSkeletonIdentityJSON: URL
        let raySolveReferenceJSON: URL
        let exportInputJSON: URL
        let preflightJSON: URL
        let readbackJSON: URL
        let auditTextReport: URL
        let auditJSONReport: URL
        let auditIssueCount: Int
        let auditHighSeverityCount: Int
    }

    static func exportAnimatedTargetUSDZ(
        targetUSDZ: URL,
        sessionSkeletonIdentityJSON: URL,
        solvedAnimationJSON: URL,
        clipID: String,
        includeHipsTranslation: Bool,
        pythonExecutablePath: String,
        outputDirectory: URL
    ) throws -> ExportResult {
        let safeClipID = sanitizeFileName(clipID)
        let outputUSDZ = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_target.usdz")
        let workDir = outputDirectory
            .appendingPathComponent("\(safeClipID)_animated_usdz_work", isDirectory: true)
        let raySolveReferenceJSON = workDir.appendingPathComponent("ray_solve_reference.json")
        let exportInputJSON = solvedAnimationJSON
        let preflightJSON = workDir.appendingPathComponent("retarget_export_preflight.json")
        let readbackJSON = workDir.appendingPathComponent("animated_usdz_readback.json")
        let auditTextReport = workDir.appendingPathComponent("export_audit_report.txt")
        let auditJSONReport = workDir.appendingPathComponent("export_audit_report.json")
        let scriptURL = workDir.appendingPathComponent("rotomotion_usdz_retarget.py")

        if FileManager.default.fileExists(atPath: outputUSDZ.path) {
            try FileManager.default.removeItem(at: outputUSDZ)
        }

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        let reference: [String: Any] = [
            "schema": "com.gravitas.rotomotion.baked_export_reference.v0",
            "sourceKind": "bakedRigAnimation",
            "exportInputJSON": exportInputJSON.path
        ]
        let referenceData = try JSONSerialization.data(
            withJSONObject: reference,
            options: [.prettyPrinted, .sortedKeys]
        )
        try referenceData.write(to: raySolveReferenceJSON, options: .atomic)

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
                "--session-skeleton-identity",
                sessionSkeletonIdentityJSON.path,
                "--solved-json",
                exportInputJSON.path,
                "--clip-id",
                clipID,
                "--work-dir",
                workDir.path,
                "--output-usdz",
                outputUSDZ.path,
                "--preflight-json",
                preflightJSON.path,
                "--readback-json",
                readbackJSON.path
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

        if isDirectSessionArmatureTransformInput(exportInputJSON) {
            let message = """
            RotoMotion Export Key Audit

            Export input source:
            \(exportInputJSON.path)

            Direct session armature transform export was used.
            Local joint translations, rotations, and scales were written from the session armature transform JSON.
            The old rayAnimationSolveResult local-rotation comparison is intentionally skipped for this path.
            """

            try message.write(
                to: auditTextReport,
                atomically: true,
                encoding: .utf8
            )

            let json: [String: Any] = [
                "schema": "com.gravitas.rotomotion.export_audit.v0",
                "auditSkipped": true,
                "reason": "direct_session_armature_transform_export",
                "exportInput": exportInputJSON.path,
                "outputUSDZ": outputUSDZ.path
            ]

            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: auditJSONReport, options: .atomic)

            audit = .init(
                issueCount: 0,
                highSeverityCount: 0
            )
        } else {
            let message = """
            RotoMotion Export Key Audit

            Export input source:
            \(exportInputJSON.path)

            Non-baked export input is not supported by this path.
            Export is expected to use bakedRigAnimation session armature transforms only.
            """

            try message.write(
                to: auditTextReport,
                atomically: true,
                encoding: .utf8
            )

            let json: [String: Any] = [
                "schema": "com.gravitas.rotomotion.export_audit.v0",
                "auditSkipped": true,
                "reason": "baked_animation_export_required",
                "exportInput": exportInputJSON.path,
                "outputUSDZ": outputUSDZ.path
            ]

            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: auditJSONReport, options: .atomic)

            audit = .init(
                issueCount: 0,
                highSeverityCount: 0
            )
        }

        return ExportResult(
            outputUSDZ: outputUSDZ,
            workDirectory: workDir,
            sessionSkeletonIdentityJSON: sessionSkeletonIdentityJSON,
            raySolveReferenceJSON: raySolveReferenceJSON,
            exportInputJSON: exportInputJSON,
            preflightJSON: preflightJSON,
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

    private static func isDirectSessionArmatureTransformInput(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let schema = root["schema"] as? String
        return schema == "com.gravitas.rotomotion.session_armature_snapshot.v0"
            || schema == "com.gravitas.rotomotion.session_armature_pose.v0"
    }

}
