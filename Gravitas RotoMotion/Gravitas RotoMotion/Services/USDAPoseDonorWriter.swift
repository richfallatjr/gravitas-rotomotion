import Foundation

enum USDAPoseDonorWriter {
    static func writeUSDA(
        capture: RawVisionPoseCapture,
        to url: URL
    ) throws {
        let fps = capture.extraction.sampleFPS > 0 ? capture.extraction.sampleFPS : 24.0
        let startFrame = 1
        let endFrame = max(capture.frames.count, 1)

        var text = ""

        text += "#usda 1.0\n"
        text += "(\n"
        text += "    defaultPrim = \"root\"\n"
        text += "    metersPerUnit = 1\n"
        text += "    timeCodesPerSecond = \(format(fps))\n"
        text += "    framesPerSecond = \(format(fps))\n"
        text += "    startTimeCode = \(startFrame)\n"
        text += "    endTimeCode = \(endFrame)\n"
        text += "    upAxis = \"Z\"\n"
        text += ")\n\n"

        text += "def Xform \"root\"\n"
        text += "{\n"
        text += "    def SkelRoot \"Armature_001\"\n"
        text += "    {\n"
        text += "        def Skeleton \"Armature\"\n"
        text += "        {\n"
        text += "            uniform token[] joints = \(stringArray(CanonicalRig.jointPaths))\n"
        text += "            uniform matrix4d[] bindTransforms = \(identityMatrixArray(count: CanonicalRig.jointPaths.count))\n"
        text += "            uniform matrix4d[] restTransforms = \(identityMatrixArray(count: CanonicalRig.jointPaths.count))\n"
        text += "            rel skel:animationSource = </root/Armature_001/Anim>\n"
        text += "        }\n\n"
        text += "        def SkelAnimation \"Anim\"\n"
        text += "        {\n"
        text += "            uniform token[] joints = \(stringArray(CanonicalRig.jointPaths))\n"
        text += writeTranslationSamples(capture: capture)
        text += writeRotationSamples(capture: capture)
        text += writeScaleSamples(capture: capture)
        text += "        }\n"
        text += "    }\n"
        text += "}\n"

        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeTranslationSamples(
        capture: RawVisionPoseCapture
    ) -> String {
        var text = ""
        text += "            float3[] translations.timeSamples = {\n"

        let frameCount = max(capture.frames.count, 1)
        for index in 0..<frameCount {
            let frame = capture.frames.indices.contains(index) ? capture.frames[index] : nil
            let timeCode = index + 1
            let values = CanonicalRig.jointNames.map { jointName -> String in
                let joint = frame?.canonicalJoints[jointName]
                let x = ((joint?.x ?? 0.5) - 0.5) * 2.0
                let z = ((joint?.y ?? 0.5) - 0.5) * 2.0
                let y = joint?.z ?? 0.0

                return "(\(format(x)), \(format(y)), \(format(z)))"
            }

            text += "                \(timeCode): [\(values.joined(separator: ", "))]"

            if index < frameCount - 1 {
                text += ","
            }

            text += "\n"
        }

        text += "            }\n"
        return text
    }

    private static func writeRotationSamples(
        capture: RawVisionPoseCapture
    ) -> String {
        var text = ""
        text += "            quatf[] rotations.timeSamples = {\n"

        let frameCount = max(capture.frames.count, 1)
        let identityRotations = Array(
            repeating: "(1, 0, 0, 0)",
            count: CanonicalRig.jointNames.count
        ).joined(separator: ", ")

        for index in 0..<frameCount {
            let timeCode = index + 1
            text += "                \(timeCode): [\(identityRotations)]"

            if index < frameCount - 1 {
                text += ","
            }

            text += "\n"
        }

        text += "            }\n"
        return text
    }

    private static func writeScaleSamples(
        capture: RawVisionPoseCapture
    ) -> String {
        var text = ""
        text += "            half3[] scales.timeSamples = {\n"

        let frameCount = max(capture.frames.count, 1)
        let scales = Array(
            repeating: "(1, 1, 1)",
            count: CanonicalRig.jointNames.count
        ).joined(separator: ", ")

        for index in 0..<frameCount {
            let timeCode = index + 1
            text += "                \(timeCode): [\(scales)]"

            if index < frameCount - 1 {
                text += ","
            }

            text += "\n"
        }

        text += "            }\n"
        return text
    }

    private static func stringArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    private static func identityMatrixArray(count: Int) -> String {
        let identity = "( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1) )"
        return "[" + Array(repeating: identity, count: count).joined(separator: ", ") + "]"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
