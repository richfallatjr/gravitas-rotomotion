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
        var beforeLocalRot: [String: SIMD4<Float>] = [:]
        var afterWorld: [String: SIMD3<Float>] = [:]
        var afterLocalRot: [String: SIMD4<Float>] = [:]

        SkinnedRigRotomationDriver.resetToRest(session: session)

        for joint in jointNames {
            if let bone = session.bonesByCanonicalName[joint] {
                beforeWorld[joint] = bone.simdWorldPosition
                beforeLocalRot[joint] = wxyz(bone.simdOrientation)
            }
        }

        SkinnedRigRotomationDriver.rotomateFrame(
            solvedFrame,
            session: session
        )

        for joint in jointNames {
            if let bone = session.bonesByCanonicalName[joint] {
                afterWorld[joint] = bone.simdWorldPosition
                afterLocalRot[joint] = wxyz(bone.simdOrientation)
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

            let solvedRot = solvedFrame.localRotationsWXYZ[joint]
            let before = beforeWorld[joint]
            let after = afterWorld[joint]
            let beforeQ = beforeLocalRot[joint]
            let afterQ = afterLocalRot[joint]

            lines.append("solved world position: \(v3(solvedPos))")
            lines.append("solved local rot WXYZ: \(solvedRot.map(v4) ?? "nil")")
            lines.append("bone world before: \(before.map(v3) ?? "nil")")
            lines.append("bone world after:  \(after.map(v3) ?? "nil")")
            lines.append("bone local rot before WXYZ: \(beforeQ.map(v4) ?? "nil")")
            lines.append("bone local rot after  WXYZ: \(afterQ.map(v4) ?? "nil")")

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

    private static func wxyz(_ q: simd_quatf) -> SIMD4<Float> {
        SIMD4<Float>(
            q.vector.w,
            q.vector.x,
            q.vector.y,
            q.vector.z
        )
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }

    private static func v3(_ v: SIMD3<Float>) -> String {
        "(\(String(format: "%.4f", v.x)), \(String(format: "%.4f", v.y)), \(String(format: "%.4f", v.z)))"
    }

    private static func v4(_ v: SIMD4<Float>) -> String {
        "(\(String(format: "%.4f", v.x)), \(String(format: "%.4f", v.y)), \(String(format: "%.4f", v.z)), \(String(format: "%.4f", v.w)))"
    }
}
