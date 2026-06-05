import Foundation
import SceneKit
import simd

enum RigPoseChainDebugger {
    static let chains: [[String]] = [
        ["Hips", "Spine", "neck", "Head"],
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
        ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    ]

    static func makeReport(
        session: SkinnedRigSession,
        solvedFrame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
        rotationApplyMode: RigRotationApplyMode = .restThenDelta
    ) -> String {
        var lines: [String] = []
        let jointNames = orderedUnique(chains.flatMap { $0 })

        lines.append("========== RIG POSE CHAIN DEBUG ==========")
        lines.append("frameIndex: \(solvedFrame.frameIndex)")
        lines.append("timeSeconds: \(fmt(solvedFrame.timeSeconds))")
        lines.append("activeDriver: SkinnedRigRotomationDriver")
        lines.append("legacyRotationApplyMode: \(rotationApplyMode.rawValue)")
        lines.append("jointOrder.count: \(session.jointOrder.count)")
        lines.append("mappedBones.count: \(session.bonesByCanonicalName.count)")
        lines.append("displayRoot.position: \(v3(session.displayRootNode.simdPosition))")
        lines.append("displayRoot.scale: \(v3(session.displayRootNode.simdScale))")
        lines.append("displayRoot.euler: \(v3(session.displayRootNode.simdEulerAngles))")
        lines.append("")

        SkinnedRigRotomationDriver.resetToRest(session: session)

        let restSnapshot = snapshot(
            session: session,
            jointNames: jointNames
        )

        SkinnedRigRotomationDriver.rotomateFrame(
            solvedFrame,
            session: session
        )

        let posedSnapshot = snapshot(
            session: session,
            jointNames: jointNames
        )

        for chain in chains {
            lines.append("----- CHAIN \(chain.joined(separator: " -> ")) -----")

            for joint in chain {
                lines.append(
                    jointReport(
                        joint: joint,
                        session: session,
                        solvedFrame: solvedFrame,
                        normalizedFrame: normalizedFrame,
                        rest: restSnapshot[joint],
                        posed: posedSnapshot[joint]
                    )
                )
            }

            lines.append("----- BONE DIRECTIONS -----")

            for i in 0..<(chain.count - 1) {
                let parent = chain[i]
                let child = chain[i + 1]

                let solvedDir = direction(
                    solvedFrame.jointPositions[parent],
                    solvedFrame.jointPositions[child]
                )

                let restDir = direction(
                    restSnapshot[parent]?.worldPosition,
                    restSnapshot[child]?.worldPosition
                )

                let posedDir = direction(
                    posedSnapshot[parent]?.worldPosition,
                    posedSnapshot[child]?.worldPosition
                )

                let solvedVsPosed = angleDegrees(solvedDir, posedDir)
                let restVsPosed = angleDegrees(restDir, posedDir)

                lines.append(
                    """
                    \(parent)->\(child)
                      solvedDir: \(solvedDir.map(v3) ?? "nil")
                      restDir:   \(restDir.map(v3) ?? "nil")
                      posedDir:  \(posedDir.map(v3) ?? "nil")
                      angle solved-vs-posed: \(fmt(solvedVsPosed))
                      angle rest-vs-posed:   \(fmt(restVsPosed))
                    """
                )
            }

            lines.append("")
        }

        lines.append("========== END RIG POSE CHAIN DEBUG ==========")

        return lines.joined(separator: "\n")
    }

    struct BoneSnapshot {
        let nodeName: String
        let localPosition: SIMD3<Float>
        let localRotationWXYZ: SIMD4<Float>
        let localScale: SIMD3<Float>
        let worldPosition: SIMD3<Float>
        let worldRotationWXYZ: SIMD4<Float>
    }

    private static func snapshot(
        session: SkinnedRigSession,
        jointNames: [String]
    ) -> [String: BoneSnapshot] {
        var result: [String: BoneSnapshot] = [:]

        for joint in jointNames {
            guard let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            result[joint] = BoneSnapshot(
                nodeName: bone.name ?? "nil",
                localPosition: bone.simdPosition,
                localRotationWXYZ: wxyz(bone.simdOrientation),
                localScale: bone.simdScale,
                worldPosition: bone.simdWorldPosition,
                worldRotationWXYZ: wxyz(bone.simdWorldOrientation)
            )
        }

        return result
    }

    private static func jointReport(
        joint: String,
        session: SkinnedRigSession,
        solvedFrame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame?,
        rest: BoneSnapshot?,
        posed: BoneSnapshot?
    ) -> String {
        let mappedName = session.bonesByCanonicalName[joint]?.name ?? "MISSING"
        let sourceSolvedJoint = CanonicalMirrorMap.sourceJoint(forTargetBone: joint)

        let n = normalizedFrame?.joints[joint]
        let normalizedText: String
        if let n {
            normalizedText = "x \(fmt(n.x)) y \(fmt(n.y)) conf \(fmt(n.confidence)) missing \(n.missing)"
        } else {
            normalizedText = "nil"
        }

        let solvedPosition = solvedFrame.jointPositions[joint]
        let sourceSolvedRotation = solvedFrame.localRotationsWXYZ[sourceSolvedJoint]

        let worldDelta: String
        if let posedPos = posed?.worldPosition,
           let solvedPosition {
            worldDelta = fmt(Double(simd_length(posedPos - solvedPosition)))
        } else {
            worldDelta = "nil"
        }

        return """
        \(joint)
          SCN bone: \(mappedName)
          legacyRotationSourceJointForTargetBone: \(sourceSolvedJoint)
          normalized: \(normalizedText)
          solvedWorld: \(solvedPosition.map(v3) ?? "nil")
          legacySourceSolvedLocalRotWXYZ: \(sourceSolvedRotation.map(v4) ?? "nil")
          rest.localPos: \(rest.map { v3($0.localPosition) } ?? "nil")
          rest.localRotWXYZ: \(rest.map { v4($0.localRotationWXYZ) } ?? "nil")
          rest.worldPos: \(rest.map { v3($0.worldPosition) } ?? "nil")
          rest.worldRotWXYZ: \(rest.map { v4($0.worldRotationWXYZ) } ?? "nil")
          posed.localPos: \(posed.map { v3($0.localPosition) } ?? "nil")
          posed.localRotWXYZ: \(posed.map { v4($0.localRotationWXYZ) } ?? "nil")
          posed.worldPos: \(posed.map { v3($0.worldPosition) } ?? "nil")
          posed.worldRotWXYZ: \(posed.map { v4($0.worldRotationWXYZ) } ?? "nil")
          posed-vs-solved world delta: \(worldDelta)
        """
    }

    private static func direction(
        _ a: SIMD3<Float>?,
        _ b: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let a, let b else {
            return nil
        }

        let v = b - a
        let len = simd_length(v)
        guard len > 0.000001 else {
            return nil
        }

        return v / len
    }

    private static func angleDegrees(
        _ a: SIMD3<Float>?,
        _ b: SIMD3<Float>?
    ) -> Double {
        guard let a, let b else {
            return -1
        }

        let d = max(-1.0, min(1.0, Double(simd_dot(a, b))))
        return acos(d) * 180.0 / .pi
    }

    private static func wxyz(_ q: simd_quatf) -> SIMD4<Float> {
        SIMD4<Float>(
            q.vector.w,
            q.vector.x,
            q.vector.y,
            q.vector.z
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []

        for value in values where !seen.contains(value) {
            seen.insert(value)
            output.append(value)
        }

        return output
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }

    private static func fmt(_ v: Float) -> String {
        String(format: "%.4f", v)
    }

    private static func v3(_ v: SIMD3<Float>) -> String {
        "(\(fmt(v.x)), \(fmt(v.y)), \(fmt(v.z)))"
    }

    private static func v4(_ v: SIMD4<Float>) -> String {
        "(\(fmt(v.x)), \(fmt(v.y)), \(fmt(v.z)), \(fmt(v.w)))"
    }
}
