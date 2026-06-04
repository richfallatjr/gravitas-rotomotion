import Foundation
import simd

enum RotoMotionExportKeyAuditor {
    struct Output {
        let issueCount: Int
        let highSeverityCount: Int
    }

    private struct RotationSeries {
        let frames: [Int]
        let values: [SIMD4<Double>]
    }

    private struct TranslationSeries {
        let frames: [Int]
        let values: [SIMD3<Double>]
    }

    static func writeAudit(
        solve: RotoRayAnimationSolveResult,
        exportInputURL: URL,
        readbackURL: URL,
        textReportURL: URL,
        jsonReportURL: URL
    ) throws -> Output {
        let inputRoot = try readJSONObject(exportInputURL)
        let readbackRoot = try readJSONObject(readbackURL)

        let inputRotations = parseInputRotations(inputRoot)
        let inputTranslations = parseInputTranslations(inputRoot)
        let readbackRotations = parseReadbackRotations(readbackRoot)
        let readbackTranslations = parseReadbackTranslations(readbackRoot)

        var issues: [[String: Any]] = []

        func addIssue(
            severity: String,
            joint: String?,
            problem: String,
            detail: String,
            frame: Int? = nil
        ) {
            var issue: [String: Any] = [
                "severity": severity,
                "problem": problem,
                "detail": detail
            ]

            if let joint {
                issue["joint"] = joint
            }

            if let frame {
                issue["frame"] = frame
            }

            issues.append(issue)
        }

        let inputFrameCount = inputRoot["frameCount"] as? Int
        let readbackRotationSampleCount = readbackRoot["rotationSampleCount"] as? Int

        if inputFrameCount != solve.frames.count {
            addIssue(
                severity: "high",
                joint: nil,
                problem: "frame count mismatch",
                detail: "Ray solve has \(solve.frames.count) frames but export input declares \(inputFrameCount ?? -1)."
            )
        }

        if readbackRotationSampleCount != solve.frames.count {
            addIssue(
                severity: "high",
                joint: nil,
                problem: "readback sample count mismatch",
                detail: "Ray solve has \(solve.frames.count) frames but USDZ readback has \(readbackRotationSampleCount ?? -1) rotation samples."
            )
        }

        if (inputRoot["quaternionOrder"] as? String) != "wxyz" {
            addIssue(
                severity: "high",
                joint: nil,
                problem: "ambiguous quaternion order",
                detail: "Export input does not declare quaternionOrder=wxyz."
            )
        }

        let skeletonJoints = readbackRoot["skeletonJoints"] as? [String] ?? []
        let animationJoints = readbackRoot["animationJoints"] as? [String] ?? []

        if skeletonJoints != animationJoints {
            addIssue(
                severity: "high",
                joint: nil,
                problem: "joint order mismatch",
                detail: "Readback SkelAnimation joint order does not exactly match skeleton joint order."
            )
        }

        let animationTargets = readbackRoot["skelAnimationSourceTargets"] as? [String] ?? []

        if animationTargets.isEmpty {
            addIssue(
                severity: "high",
                joint: nil,
                problem: "missing animation binding",
                detail: "Skeleton has no skel:animationSource target in readback."
            )
        }

        for jointName in CanonicalRig.jointNames {
            let solveRotations = RotationSeries(
                frames: solve.frames.map(\.frameIndex),
                values: solve.frames.map {
                    let q = $0.localRotationsWXYZ[jointName] ?? SIMD4<Float>(1, 0, 0, 0)
                    return SIMD4<Double>(Double(q.x), Double(q.y), Double(q.z), Double(q.w))
                }
            )

            guard let inputRotationSeries = inputRotations[jointName] else {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "missing exporter input joint",
                    detail: "Joint exists in ray solve but not animated_usdz_export_input.json."
                )
                continue
            }

            guard let readbackRotationSeries = readbackRotations[jointName] else {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "missing USDZ readback joint",
                    detail: "Joint exists in export input but not animated_usdz_readback.json."
                )
                continue
            }

            let solveStats = rotationStats(solveRotations)
            let inputStats = rotationStats(inputRotationSeries)
            let readbackStats = rotationStats(readbackRotationSeries)

            if inputRotationSeries.values.count != solve.frames.count {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "input frame count mismatch",
                    detail: "Input has \(inputRotationSeries.values.count) keys; ray solve has \(solve.frames.count)."
                )
            }

            if readbackRotationSeries.values.count != inputRotationSeries.values.count {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "readback frame count mismatch",
                    detail: "Readback has \(readbackRotationSeries.values.count) keys; input has \(inputRotationSeries.values.count)."
                )
            }

            if inputStats.signFlips > 0 {
                addIssue(
                    severity: "medium",
                    joint: jointName,
                    problem: "input quaternion sign flip",
                    detail: "Exporter input has \(inputStats.signFlips) raw quaternion sign flips. This can cause interpolation flips in tools that do not canonicalize signs."
                )
            }

            if readbackStats.signFlips > 0 {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "readback quaternion sign flip",
                    detail: "USDZ readback has \(readbackStats.signFlips) raw quaternion sign flips."
                )
            }

            if solveStats.maxDeltaDegrees > 90 {
                addIssue(
                    severity: "medium",
                    joint: jointName,
                    problem: "ray solve rotation jump",
                    detail: "Viewport solve rotation delta reaches \(format(solveStats.maxDeltaDegrees)) degrees."
                )
            }

            if inputStats.maxDeltaDegrees > solveStats.maxDeltaDegrees + 20,
               inputStats.maxDeltaDegrees > 45 {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "Swift export conversion enlarged rotation jump",
                    detail: "Input delta \(format(inputStats.maxDeltaDegrees)) degrees vs solve delta \(format(solveStats.maxDeltaDegrees)) degrees."
                )
            }

            if readbackStats.maxDeltaDegrees > inputStats.maxDeltaDegrees + 20,
               readbackStats.maxDeltaDegrees > 45 {
                addIssue(
                    severity: "high",
                    joint: jointName,
                    problem: "OpenUSD authoring enlarged rotation jump",
                    detail: "Readback delta \(format(readbackStats.maxDeltaDegrees)) degrees vs input delta \(format(inputStats.maxDeltaDegrees)) degrees."
                )
            }
        }

        if let inputHips = inputTranslations["Hips"],
           let readbackHips = readbackTranslations["Hips"],
           let firstReadback = readbackHips.values.first {
            let inputTravel = totalTravel(inputHips.values)
            let readbackTravel = totalTravel(readbackHips.values)
            let staticOffset = simd_length(firstReadback)

            if inputTravel > 0.0001 {
                let ratio = readbackTravel / inputTravel

                if ratio > 10 || ratio < 0.1 {
                    addIssue(
                        severity: "high",
                        joint: "Hips",
                        problem: "translation scale mismatch",
                        detail: "Readback Hips travel is \(format(ratio))x exporter input travel."
                    )
                }
            }

            if staticOffset > 10 {
                addIssue(
                    severity: "medium",
                    joint: "Hips",
                    problem: "large root rest translation in readback",
                    detail: "Readback Hips starts at distance \(format(staticOffset)) from origin. This can indicate target rest transforms are being authored as animation translations."
                )
            }
        }

        let highCount = issues.filter { ($0["severity"] as? String) == "high" }.count
        let reportRoot: [String: Any] = [
            "schema": "com.gravitas.rotomotion.export_audit.v0",
            "sourceFiles": [
                "exportInput": exportInputURL.path,
                "readback": readbackURL.path
            ],
            "summary": [
                "issueCount": issues.count,
                "highSeverityCount": highCount,
                "solveFrameCount": solve.frames.count,
                "inputFrameCount": inputFrameCount ?? -1,
                "readbackRotationSampleCount": readbackRotationSampleCount ?? -1
            ],
            "issues": issues
        ]

        let jsonData = try JSONSerialization.data(
            withJSONObject: reportRoot,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: jsonReportURL, options: .atomic)

        try makeTextReport(
            issues: issues,
            solveFrameCount: solve.frames.count,
            inputFrameCount: inputFrameCount,
            readbackFrameCount: readbackRotationSampleCount
        ).write(to: textReportURL, atomically: true, encoding: .utf8)

        return Output(
            issueCount: issues.count,
            highSeverityCount: highCount
        )
    }

    private static func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 8301,
                userInfo: [NSLocalizedDescriptionKey: "Expected JSON object at \(url.path)."]
            )
        }

        return object
    }

    private static func parseInputRotations(_ root: [String: Any]) -> [String: RotationSeries] {
        guard let joints = root["joints"] as? [String: [[Any]]] else {
            return [:]
        }

        return joints.mapValues { keys in
            var frames: [Int] = []
            var values: [SIMD4<Double>] = []

            for key in keys {
                guard key.count >= 8,
                      let frame = intValue(key[0]) else {
                    continue
                }

                if key.count == 9, key[8] is String,
                   let qw = doubleValue(key[4]),
                   let qx = doubleValue(key[5]),
                   let qy = doubleValue(key[6]),
                   let qz = doubleValue(key[7]) {
                    frames.append(frame)
                    values.append(normalizeQuaternion(SIMD4<Double>(qw, qx, qy, qz)))
                } else if key.count == 9,
                          let legacy = key[8] as? [Any],
                          legacy.count == 4,
                          let qw = doubleValue(legacy[0]),
                          let qx = doubleValue(legacy[1]),
                          let qy = doubleValue(legacy[2]),
                          let qz = doubleValue(legacy[3]) {
                    frames.append(frame)
                    values.append(normalizeQuaternion(SIMD4<Double>(qw, qx, qy, qz)))
                }
            }

            return RotationSeries(frames: frames, values: values)
        }
    }

    private static func parseInputTranslations(_ root: [String: Any]) -> [String: TranslationSeries] {
        guard let joints = root["joints"] as? [String: [[Any]]] else {
            return [:]
        }

        return joints.mapValues { keys in
            var frames: [Int] = []
            var values: [SIMD3<Double>] = []

            for key in keys {
                guard key.count >= 4,
                      let frame = intValue(key[0]),
                      let x = doubleValue(key[1]),
                      let y = doubleValue(key[2]),
                      let z = doubleValue(key[3]) else {
                    continue
                }

                frames.append(frame)
                values.append(SIMD3<Double>(x, y, z))
            }

            return TranslationSeries(frames: frames, values: values)
        }
    }

    private static func parseReadbackRotations(_ root: [String: Any]) -> [String: RotationSeries] {
        guard let joints = root["rotations"] as? [String: [[Any]]] else {
            return [:]
        }

        return joints.mapValues { keys in
            var frames: [Int] = []
            var values: [SIMD4<Double>] = []

            for key in keys {
                guard key.count >= 5,
                      let frame = intValue(key[0]),
                      let qw = doubleValue(key[1]),
                      let qx = doubleValue(key[2]),
                      let qy = doubleValue(key[3]),
                      let qz = doubleValue(key[4]) else {
                    continue
                }

                frames.append(frame)
                values.append(normalizeQuaternion(SIMD4<Double>(qw, qx, qy, qz)))
            }

            return RotationSeries(frames: frames, values: values)
        }
    }

    private static func parseReadbackTranslations(_ root: [String: Any]) -> [String: TranslationSeries] {
        guard let joints = root["translations"] as? [String: [[Any]]] else {
            return [:]
        }

        return joints.mapValues { keys in
            var frames: [Int] = []
            var values: [SIMD3<Double>] = []

            for key in keys {
                guard key.count >= 4,
                      let frame = intValue(key[0]),
                      let x = doubleValue(key[1]),
                      let y = doubleValue(key[2]),
                      let z = doubleValue(key[3]) else {
                    continue
                }

                frames.append(frame)
                values.append(SIMD3<Double>(x, y, z))
            }

            return TranslationSeries(frames: frames, values: values)
        }
    }

    private static func rotationStats(_ series: RotationSeries) -> (
        maxDeltaDegrees: Double,
        signFlips: Int
    ) {
        guard series.values.count > 1 else {
            return (0, 0)
        }

        var maxDelta = 0.0
        var signFlips = 0

        for index in 1..<series.values.count {
            let previous = series.values[index - 1]
            let current = series.values[index]
            let rawDot = dot(previous, current)

            if rawDot < 0 {
                signFlips += 1
            }

            maxDelta = max(maxDelta, quaternionDeltaDegrees(previous, current))
        }

        return (maxDelta, signFlips)
    }

    private static func quaternionDeltaDegrees(
        _ a: SIMD4<Double>,
        _ b: SIMD4<Double>
    ) -> Double {
        let clamped = min(max(abs(dot(a, b)), -1), 1)
        return 2 * acos(clamped) * 180 / .pi
    }

    private static func normalizeQuaternion(_ value: SIMD4<Double>) -> SIMD4<Double> {
        let length = sqrt(dot(value, value))

        guard length > 0.0000001 else {
            return SIMD4<Double>(1, 0, 0, 0)
        }

        return value / length
    }

    private static func totalTravel(_ values: [SIMD3<Double>]) -> Double {
        guard values.count > 1 else {
            return 0
        }

        var travel = 0.0

        for index in 1..<values.count {
            travel += simd_length(values[index] - values[index - 1])
        }

        return travel
    }

    private static func dot(
        _ a: SIMD4<Double>,
        _ b: SIMD4<Double>
    ) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }

    private static func intValue(_ value: Any) -> Int? {
        if let int = value as? Int {
            return int
        }

        if let double = value as? Double {
            return Int(double)
        }

        return nil
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if let double = value as? Double {
            return double
        }

        if let int = value as? Int {
            return Double(int)
        }

        return nil
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func makeTextReport(
        issues: [[String: Any]],
        solveFrameCount: Int,
        inputFrameCount: Int?,
        readbackFrameCount: Int?
    ) -> String {
        var lines: [String] = [
            "RotoMotion Export Key Audit",
            "",
            "Frames:",
            "  ray solve: \(solveFrameCount)",
            "  export input: \(inputFrameCount ?? -1)",
            "  USDZ readback: \(readbackFrameCount ?? -1)",
            "",
            "Issues: \(issues.count)",
            ""
        ]

        if issues.isEmpty {
            lines.append("No suspicious export key patterns detected.")
            return lines.joined(separator: "\n")
        }

        for issue in issues {
            let severity = issue["severity"] as? String ?? "unknown"
            let joint = issue["joint"] as? String
            let problem = issue["problem"] as? String ?? "unknown"
            let detail = issue["detail"] as? String ?? ""
            let frame = issue["frame"] as? Int

            let label = joint.map { "\($0): " } ?? ""
            let frameText = frame.map { " frame \($0)" } ?? ""
            lines.append("[\(severity)] \(label)\(problem)\(frameText)")
            lines.append("  \(detail)")
        }

        return lines.joined(separator: "\n")
    }
}
