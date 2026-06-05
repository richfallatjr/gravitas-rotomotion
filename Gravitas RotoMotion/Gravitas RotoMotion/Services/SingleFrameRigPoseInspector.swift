import Foundation
import SceneKit
import simd

struct SingleFrameRigPoseInspectionReport {
    let summary: String
    let fullText: String
}

enum SingleFrameRigPoseInspector {
    static func inspect(
        session: SkinnedRigSession,
        solvedFrame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
        jointNames: [String]
    ) -> SingleFrameRigPoseInspectionReport {
        var lines: [String] = []

        lines.append("=== Single Frame Rig Pose Inspector ===")
        lines.append("frameIndex: \(solvedFrame.frameIndex)")
        lines.append("timeSeconds: \(String(format: "%.4f", solvedFrame.timeSeconds))")
        lines.append("activeDriver: SkinnedRigRotomationDriver")
        lines.append("session jointOrder count: \(session.jointOrder.count)")
        lines.append("mapped bones count: \(session.bonesByCanonicalName.count)")
        lines.append("")

        var beforeWorld: [String: SIMD3<Float>] = [:]
        var beforeLocalRot: [String: SIMD3<Float>] = [:]
        var afterWorld: [String: SIMD3<Float>] = [:]
        var afterLocalRot: [String: SIMD3<Float>] = [:]

        SkinnedRigRotomationDriver.resetToRest(session: session)

        for joint in jointNames {
            if let bone = session.bonesByCanonicalName[joint] {
                beforeWorld[joint] = bone.simdWorldPosition
                beforeLocalRot[joint] = bone.simdEulerAngles
            }
        }

        SkinnedRigRotomationDriver.rotomateFrame(
            solvedFrame,
            session: session
        )

        for joint in jointNames {
            if let bone = session.bonesByCanonicalName[joint] {
                afterWorld[joint] = bone.simdWorldPosition
                afterLocalRot[joint] = bone.simdEulerAngles
            }
        }

        var largestWorldError: (joint: String, error: Float)?
        var missingSolved: [String] = []
        var missingBones: [String] = []

        for joint in jointNames {
            lines.append("--- \(joint) ---")

            guard let bone = session.bonesByCanonicalName[joint] else {
                lines.append("SCN bone: MISSING")
                missingBones.append(joint)
                lines.append("")
                continue
            }

            lines.append("SCN node name: \(bone.name ?? "nil")")

            if let n = normalizedFrame?.joints[joint] {
                lines.append(
                    "normalized: x \(fmt(n.x)) y \(fmt(n.y)) conf \(fmt(n.confidence)) missing \(n.missing)"
                )
            } else {
                lines.append("normalized: missing")
            }

            guard let solvedPos = solvedFrame.jointPositions[joint] else {
                lines.append("solved world position: MISSING")
                missingSolved.append(joint)
                lines.append("")
                continue
            }

            let solvedRot = solvedFrame.localRotationsEulerXYZ[joint]
            let before = beforeWorld[joint]
            let after = afterWorld[joint]
            let beforeQ = beforeLocalRot[joint]
            let afterQ = afterLocalRot[joint]

            lines.append("solved world position: \(v3(solvedPos))")
            lines.append("solved local rot EulerXYZ: \(solvedRot.map(v3) ?? "nil")")
            lines.append("bone world before: \(before.map(v3) ?? "nil")")
            lines.append("bone world after:  \(after.map(v3) ?? "nil")")
            lines.append("bone local rot before EulerXYZ: \(beforeQ.map(v3) ?? "nil")")
            lines.append("bone local rot after  EulerXYZ: \(afterQ.map(v3) ?? "nil")")

            if let after {
                let error = simd_length(after - solvedPos)
                lines.append("world position delta after-vs-solved: \(String(format: "%.5f", error))")

                if largestWorldError == nil || error > largestWorldError!.error {
                    largestWorldError = (joint, error)
                }
            }

            lines.append("")
        }

        let largestErrorText: String
        if let largestWorldError {
            largestErrorText = "\(largestWorldError.joint) \(String(format: "%.4f", largestWorldError.error))"
        } else {
            largestErrorText = "none"
        }

        let summary = """
        Joint debug frame \(solvedFrame.frameIndex).
        missingBones \(missingBones.count), missingSolved \(missingSolved.count).
        largest after-vs-solved error: \(largestErrorText)
        """

        lines.insert(summary, at: 0)

        return SingleFrameRigPoseInspectionReport(
            summary: summary,
            fullText: lines.joined(separator: "\n")
        )
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }

    private static func v3(_ v: SIMD3<Float>) -> String {
        "(\(String(format: "%.4f", v.x)), \(String(format: "%.4f", v.y)), \(String(format: "%.4f", v.z)))"
    }

}
