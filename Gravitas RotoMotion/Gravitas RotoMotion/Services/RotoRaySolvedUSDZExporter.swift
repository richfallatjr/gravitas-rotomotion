import Foundation
import simd

enum RotoRaySolvedUSDZExporter {
    static func exportUSDZ(
        result: RotoRayAnimationSolveResult,
        clipID: String,
        outputDirectory: URL
    ) throws -> URL {
        guard !result.frames.isEmpty else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 9001,
                userInfo: [NSLocalizedDescriptionKey: "No ray-solved frames available for USDZ export."]
            )
        }

        let safeClipID = sanitizeFileName(clipID)
        let workDir = outputDirectory
            .appendingPathComponent("\(safeClipID)_ray_solve_usdz_work", isDirectory: true)
        let usdaURL = workDir.appendingPathComponent("\(safeClipID)_ray_solved_armature.usda")
        let usdzURL = outputDirectory.appendingPathComponent("\(safeClipID)_ray_solved_armature.usdz")

        if FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }

        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )

        try makeUSDA(result: result, clipID: clipID)
            .write(to: usdaURL, atomically: true, encoding: .utf8)

        try USDZPackager.packageUSDAAsUSDZ(
            usdaURL: usdaURL,
            usdzURL: usdzURL
        )

        return usdzURL
    }

    private static func makeUSDA(
        result: RotoRayAnimationSolveResult,
        clipID: String
    ) -> String {
        let frames = result.frames.sorted { $0.timeSeconds < $1.timeSeconds }
        let fps = inferredFPS(frames: frames)
        let firstTimeCode = frames.first?.frameIndex ?? 0
        let lastTimeCode = frames.last?.frameIndex ?? firstTimeCode

        var lines: [String] = []

        lines.append("#usda 1.0")
        lines.append("(")
        lines.append("    defaultPrim = \"RotoMotionRaySolvedRig\"")
        lines.append("    startTimeCode = \(firstTimeCode)")
        lines.append("    endTimeCode = \(lastTimeCode)")
        lines.append("    framesPerSecond = \(format(fps))")
        lines.append("    timeCodesPerSecond = \(format(fps))")
        lines.append("    metersPerUnit = 1")
        lines.append("    upAxis = \"Y\"")
        lines.append(")")
        lines.append("")
        lines.append("def Xform \"RotoMotionRaySolvedRig\"")
        lines.append("{")
        lines.append("    custom string schema = \"\(escape(result.schema))\"")
        lines.append("    custom string clipID = \"\(escape(clipID))\"")
        lines.append("    custom string sourceKind = \"\(escape(result.sourceKind))\"")
        lines.append("    custom double targetHeightMeters = \(format(result.targetHeightMeters))")
        lines.append("    custom double sceneUnitsPerMeter = \(format(result.sceneUnitsPerMeter))")
        lines.append("    custom double armatureSceneScale = \(format(result.armatureSceneScale))")
        lines.append("")
        lines.append("    def Xform \"Joints\"")
        lines.append("    {")

        for jointName in CanonicalRig.jointNames {
            let samples = frames.compactMap { frame -> (Int, SIMD3<Float>)? in
                guard let position = frame.jointPositions[jointName] else {
                    return nil
                }

                return (frame.frameIndex, position)
            }

            guard !samples.isEmpty else {
                continue
            }

            appendJoint(
                name: jointName,
                samples: samples,
                lines: &lines
            )
        }

        lines.append("    }")
        lines.append("")
        lines.append("    def Xform \"Bones\"")
        lines.append("    {")

        for bone in bones {
            let samples = frames.compactMap { frame -> BoneSample? in
                guard let parent = frame.jointPositions[bone.0],
                      let child = frame.jointPositions[bone.1] else {
                    return nil
                }

                return makeBoneSample(
                    frameIndex: frame.frameIndex,
                    parent: parent,
                    child: child
                )
            }

            guard !samples.isEmpty else {
                continue
            }

            appendBone(
                parentName: bone.0,
                childName: bone.1,
                samples: samples,
                lines: &lines
            )
        }

        lines.append("    }")
        lines.append("}")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func appendJoint(
        name: String,
        samples: [(Int, SIMD3<Float>)],
        lines: inout [String]
    ) {
        lines.append("        def Xform \"\(primName("Joint_\(name)"))\"")
        lines.append("        {")
        appendVec3TimeSamples(
            typeName: "double3",
            opName: "xformOp:translate",
            samples: samples,
            indent: "            ",
            lines: &lines
        )
        lines.append("            uniform token[] xformOpOrder = [\"xformOp:translate\"]")
        lines.append("            def Sphere \"Geo\"")
        lines.append("            {")
        lines.append("                double radius = 0.075")
        lines.append("                color3f[] primvars:displayColor = [(0.0, 1.0, 0.15)]")
        lines.append("            }")
        lines.append("        }")
    }

    private static func appendBone(
        parentName: String,
        childName: String,
        samples: [BoneSample],
        lines: inout [String]
    ) {
        lines.append("        def Xform \"\(primName("Bone_\(parentName)_\(childName)"))\"")
        lines.append("        {")
        appendVec3TimeSamples(
            typeName: "double3",
            opName: "xformOp:translate",
            samples: samples.map { ($0.frameIndex, $0.midpoint) },
            indent: "            ",
            lines: &lines
        )
        appendQuatTimeSamples(
            samples: samples.map { ($0.frameIndex, $0.orientationWXYZ) },
            indent: "            ",
            lines: &lines
        )
        appendVec3TimeSamples(
            typeName: "float3",
            opName: "xformOp:scale",
            samples: samples.map { ($0.frameIndex, SIMD3<Float>(1, $0.length, 1)) },
            indent: "            ",
            lines: &lines
        )
        lines.append("            uniform token[] xformOpOrder = [\"xformOp:translate\", \"xformOp:orient\", \"xformOp:scale\"]")
        lines.append("            def Cylinder \"Geo\"")
        lines.append("            {")
        lines.append("                double height = 1")
        lines.append("                double radius = 0.025")
        lines.append("                token axis = \"Y\"")
        lines.append("                color3f[] primvars:displayColor = [(0.0, 0.85, 0.1)]")
        lines.append("            }")
        lines.append("        }")
    }

    private static func appendVec3TimeSamples(
        typeName: String,
        opName: String,
        samples: [(Int, SIMD3<Float>)],
        indent: String,
        lines: inout [String]
    ) {
        lines.append("\(indent)\(typeName) \(opName).timeSamples = {")

        for sample in samples {
            lines.append("\(indent)    \(sample.0): (\(format(sample.1.x)), \(format(sample.1.y)), \(format(sample.1.z))),")
        }

        lines.append("\(indent)}")
    }

    private static func appendQuatTimeSamples(
        samples: [(Int, SIMD4<Float>)],
        indent: String,
        lines: inout [String]
    ) {
        lines.append("\(indent)quatf xformOp:orient.timeSamples = {")

        for sample in samples {
            lines.append("\(indent)    \(sample.0): (\(format(sample.1.x)), \(format(sample.1.y)), \(format(sample.1.z)), \(format(sample.1.w))),")
        }

        lines.append("\(indent)}")
    }

    private struct BoneSample {
        let frameIndex: Int
        let midpoint: SIMD3<Float>
        let orientationWXYZ: SIMD4<Float>
        let length: Float
    }

    private static func makeBoneSample(
        frameIndex: Int,
        parent: SIMD3<Float>,
        child: SIMD3<Float>
    ) -> BoneSample {
        let vector = child - parent
        let length = max(simd_length(vector), 0.0001)
        let direction = vector / length
        let orientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: direction
        )

        return BoneSample(
            frameIndex: frameIndex,
            midpoint: parent + vector * 0.5,
            orientationWXYZ: SIMD4<Float>(
                orientation.real,
                orientation.imag.x,
                orientation.imag.y,
                orientation.imag.z
            ),
            length: length
        )
    }

    private static func inferredFPS(
        frames: [RotoRayAnimationSolveResult.Frame]
    ) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 24
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }

    private static let bones: [(String, String)] = [
        ("Hips", "Spine02"),
        ("Spine02", "Spine01"),
        ("Spine01", "Spine"),
        ("Spine", "neck"),
        ("neck", "Head"),
        ("Head", "head_end"),
        ("Head", "headfront"),
        ("Spine", "LeftShoulder"),
        ("LeftShoulder", "LeftArm"),
        ("LeftArm", "LeftForeArm"),
        ("LeftForeArm", "LeftHand"),
        ("Spine", "RightShoulder"),
        ("RightShoulder", "RightArm"),
        ("RightArm", "RightForeArm"),
        ("RightForeArm", "RightHand"),
        ("Hips", "LeftUpLeg"),
        ("LeftUpLeg", "LeftLeg"),
        ("LeftLeg", "LeftFoot"),
        ("LeftFoot", "LeftToeBase"),
        ("Hips", "RightUpLeg"),
        ("RightUpLeg", "RightLeg"),
        ("RightLeg", "RightFoot"),
        ("RightFoot", "RightToeBase")
    ]

    private static func primName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        var name = String(scalars)

        if name.isEmpty {
            name = "Prim"
        }

        if let first = name.unicodeScalars.first,
           CharacterSet.decimalDigits.contains(first) {
            name = "_\(name)"
        }

        return name
    }

    private static func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)

        let sanitized = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")

        return sanitized.isEmpty ? "rotomotion_ray_solve" : sanitized
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.6f", value)
    }
}
