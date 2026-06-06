import Foundation
import SceneKit
import simd

struct Skin3DCanonicalTargetFrame {
    let frameIndex: Int
    let timeSeconds: Double
    let targetsByJoint: [String: Target]

    struct Target {
        let position: SIMD3<Float>
        let confidence: Float
        let source: String
        let inferred: Bool
    }
}

enum Vision3DCanonicalTargetBuilder {
    static func build(
        frame: NormalizedVision3DMeshyCapture.Frame
    ) -> Skin3DCanonicalTargetFrame {
        var targets: [String: Skin3DCanonicalTargetFrame.Target] = [:]

        func joint(_ name: String) -> NormalizedVision3DMeshyCapture.Joint? {
            guard let joint = frame.joints[name],
                  joint.confidence > 0 else {
                return nil
            }

            return joint
        }

        func read(_ name: String) -> SIMD3<Float>? {
            guard let joint = joint(name) else {
                return nil
            }

            return SIMD3<Float>(
                Float(joint.x),
                Float(joint.y),
                Float(joint.z)
            )
        }

        func confidence(_ name: String) -> Float {
            Float(joint(name)?.confidence ?? 0)
        }

        func put(
            _ name: String,
            _ position: SIMD3<Float>?,
            confidence: Float = 1.0,
            source: String,
            inferred: Bool = false
        ) {
            guard let position else {
                return
            }

            targets[name] = .init(
                position: position,
                confidence: confidence,
                source: source,
                inferred: inferred
            )
        }

        let hips = read("Hips")
        let spine = read("Spine")
        let head = read("Head")
        let headEnd = read("head_end")
        let neck = read("neck") ?? interpolate(spine, head, 0.70)

        put("Hips", hips, confidence: confidence("Hips"), source: "vision3d_root")
        put("Spine", spine, confidence: confidence("Spine"), source: "vision3d_spine")
        put(
            "neck",
            neck,
            confidence: max(confidence("neck"), min(confidence("Spine"), confidence("Head")) * 0.5),
            source: read("neck") == nil ? "inferred_spine_head" : "vision3d_center_shoulder",
            inferred: read("neck") == nil
        )
        put("Head", head, confidence: confidence("Head"), source: "vision3d_head")
        put(
            "head_end",
            headEnd ?? extend(head, from: spine, amount: 0.18),
            confidence: max(confidence("head_end"), confidence("Head") * 0.5),
            source: headEnd == nil ? "inferred_head_end" : "vision3d_top_head",
            inferred: headEnd == nil
        )

        put("Spine02", interpolate(hips, spine, 0.33), source: "inferred_spine_chain", inferred: true)
        put("Spine01", interpolate(hips, spine, 0.66), source: "inferred_spine_chain", inferred: true)

        let leftShoulderBall = read("LeftArm")
        let rightShoulderBall = read("RightArm")
        let leftElbow = read("LeftForeArm")
        let rightElbow = read("RightForeArm")
        let leftWrist = read("LeftHand")
        let rightWrist = read("RightHand")

        put("LeftArm", leftShoulderBall, confidence: confidence("LeftArm"), source: "vision3d_left_shoulder")
        put("RightArm", rightShoulderBall, confidence: confidence("RightArm"), source: "vision3d_right_shoulder")
        put(
            "LeftShoulder",
            interpolate(neck, leftShoulderBall, 0.65),
            source: "inferred_left_clavicle",
            inferred: true
        )
        put(
            "RightShoulder",
            interpolate(neck, rightShoulderBall, 0.65),
            source: "inferred_right_clavicle",
            inferred: true
        )
        put("LeftForeArm", leftElbow, confidence: confidence("LeftForeArm"), source: "vision3d_left_elbow")
        put("RightForeArm", rightElbow, confidence: confidence("RightForeArm"), source: "vision3d_right_elbow")
        put("LeftHand", leftWrist, confidence: confidence("LeftHand"), source: "vision3d_left_wrist")
        put("RightHand", rightWrist, confidence: confidence("RightHand"), source: "vision3d_right_wrist")

        put("LeftUpLeg", read("LeftUpLeg"), confidence: confidence("LeftUpLeg"), source: "vision3d_left_hip")
        put("RightUpLeg", read("RightUpLeg"), confidence: confidence("RightUpLeg"), source: "vision3d_right_hip")
        put("LeftLeg", read("LeftLeg"), confidence: confidence("LeftLeg"), source: "vision3d_left_knee")
        put("RightLeg", read("RightLeg"), confidence: confidence("RightLeg"), source: "vision3d_right_knee")
        put("LeftFoot", read("LeftFoot"), confidence: confidence("LeftFoot"), source: "vision3d_left_ankle")
        put("RightFoot", read("RightFoot"), confidence: confidence("RightFoot"), source: "vision3d_right_ankle")
        put(
            "LeftToeBase",
            inferToe(ankle: read("LeftFoot"), knee: read("LeftLeg")),
            source: "inferred_left_toe",
            inferred: true
        )
        put(
            "RightToeBase",
            inferToe(ankle: read("RightFoot"), knee: read("RightLeg")),
            source: "inferred_right_toe",
            inferred: true
        )

        put(
            "headfront",
            inferHeadFront(head: head),
            source: "inferred_headfront",
            inferred: true
        )

        return Skin3DCanonicalTargetFrame(
            frameIndex: frame.frameIndex,
            timeSeconds: frame.timeSeconds,
            targetsByJoint: targets
        )
    }

    private static func interpolate(
        _ a: SIMD3<Float>?,
        _ b: SIMD3<Float>?,
        _ amount: Float
    ) -> SIMD3<Float>? {
        guard let a, let b else {
            return nil
        }

        return a + (b - a) * amount
    }

    private static func extend(
        _ a: SIMD3<Float>?,
        from b: SIMD3<Float>?,
        amount: Float
    ) -> SIMD3<Float>? {
        guard let a, let b else {
            return nil
        }

        let direction = a - b
        guard simd_length(direction) > 0.0001 else {
            return a
        }

        return a + simd_normalize(direction) * amount
    }

    private static func inferToe(
        ankle: SIMD3<Float>?,
        knee: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let ankle, let knee else {
            return nil
        }

        let legDirection = ankle - knee
        guard simd_length(legDirection) > 0.0001 else {
            return ankle
        }

        return ankle + simd_normalize(legDirection) * 0.16 + SIMD3<Float>(0, -0.04, 0)
    }

    private static func inferHeadFront(
        head: SIMD3<Float>?
    ) -> SIMD3<Float>? {
        guard let head else {
            return nil
        }

        return head + SIMD3<Float>(0, 0, -0.10)
    }
}

enum Skin3DRigTopology {
    static let chains: [[String]] = [
        ["Hips", "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["Hips", "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
        ["Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "head_end"],
        ["Spine", "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["Spine", "RightShoulder", "RightArm", "RightForeArm", "RightHand"]
    ]

    static var edges: [(parent: String, child: String)] {
        chains.flatMap { chain in
            zip(chain.dropLast(), chain.dropFirst()).map { edge in
                (parent: edge.0, child: edge.1)
            }
        }
    }
}

enum Vision3DSkinningDriver {
    struct Alignment {
        let valid: Bool
        let scale: Float
        let rotation: simd_quatf
        let translation: SIMD3<Float>
    }

    struct Stats {
        let frameIndex: Int
        let targetCount: Int
        let avgTargetError: Float
        let worstJoint: String
        let worstError: Float
        let alignmentValid: Bool
        let alignmentScale: Float
    }

    static func skinFrame(
        _ frame: NormalizedVision3DMeshyCapture.Frame,
        session: SkinnedRigSession,
        alignment: Alignment,
        iterations: Int = 10
    ) -> Stats {
        resetBonesToRestOnly(session: session)

        guard alignment.valid else {
            return Stats(
                frameIndex: frame.frameIndex,
                targetCount: 0,
                avgTargetError: 0,
                worstJoint: "none",
                worstError: 0,
                alignmentValid: false,
                alignmentScale: 1
            )
        }

        let rawTargets = Vision3DCanonicalTargetBuilder.build(frame: frame)
        let targets = transformTargets(rawTargets, alignment: alignment)

        placeRootFromTargets(targets, session: session)

        for _ in 0..<iterations {
            for chain in Skin3DRigTopology.chains {
                solveChainByBoneDirections(
                    chain,
                    targets: targets,
                    session: session
                )
            }
        }

        let stats = makeStats(
            frameIndex: frame.frameIndex,
            targets: targets,
            session: session,
            alignment: alignment
        )

        if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
            logSkin3DConnectedRetarget(
                frameIndex: frame.frameIndex,
                targets: targets,
                session: session,
                stats: stats
            )
        }

        return stats
    }

    static func solveInitialAlignment(
        firstFrame: NormalizedVision3DMeshyCapture.Frame,
        session: SkinnedRigSession
    ) -> Alignment {
        let rawTargets = Vision3DCanonicalTargetBuilder.build(frame: firstFrame)
        let stableJoints = [
            "Hips",
            "Spine",
            "neck",
            "Head",
            "LeftArm",
            "RightArm",
            "LeftUpLeg",
            "RightUpLeg"
        ]

        var source: [String: SIMD3<Float>] = [:]
        var target: [String: SIMD3<Float>] = [:]

        for joint in stableJoints {
            guard let sourcePosition = rawTargets.targetsByJoint[joint]?.position,
                  let bone = session.bonesByCanonicalName[joint] else {
                continue
            }

            source[joint] = sourcePosition
            target[joint] = bone.simdWorldPosition
        }

        guard source.count >= 4,
              let sourceBasis = bodyBasis(points: source),
              let targetBasis = bodyBasis(points: target) else {
            return .invalid
        }

        let sourceCenter = center(Array(source.values))
        let targetCenter = center(Array(target.values))
        let sourceRadius = averageRadius(Array(source.values), center: sourceCenter)
        let targetRadius = averageRadius(Array(target.values), center: targetCenter)

        guard sourceRadius > 0.0001,
              targetRadius > 0.0001 else {
            return .invalid
        }

        let scale = targetRadius / sourceRadius
        let rotationMatrix = targetBasis * sourceBasis.transpose
        let rotation = simd_quatf(rotationMatrix)
        let translation = targetCenter - rotation.act(sourceCenter * scale)

        return Alignment(
            valid: true,
            scale: scale,
            rotation: rotation,
            translation: translation
        )
    }

    private static func transformTargets(
        _ frame: Skin3DCanonicalTargetFrame,
        alignment: Alignment
    ) -> Skin3DCanonicalTargetFrame {
        var output: [String: Skin3DCanonicalTargetFrame.Target] = [:]

        for (joint, target) in frame.targetsByJoint {
            let position = alignment.rotation.act(target.position * alignment.scale) + alignment.translation

            output[joint] = .init(
                position: position,
                confidence: target.confidence,
                source: target.source,
                inferred: target.inferred
            )
        }

        return Skin3DCanonicalTargetFrame(
            frameIndex: frame.frameIndex,
            timeSeconds: frame.timeSeconds,
            targetsByJoint: output
        )
    }

    private static func placeRootFromTargets(
        _ targets: Skin3DCanonicalTargetFrame,
        session: SkinnedRigSession
    ) {
        let driverJoints = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg",
            "Spine02"
        ]

        var deltas: [SIMD3<Float>] = []

        for joint in driverJoints {
            guard let bone = session.bonesByCanonicalName[joint],
                  let target = targets.targetsByJoint[joint] else {
                continue
            }

            deltas.append(target.position - bone.simdWorldPosition)
        }

        guard !deltas.isEmpty else {
            return
        }

        let average = deltas.reduce(SIMD3<Float>(0, 0, 0), +) / Float(deltas.count)
        session.displayRootNode.simdPosition += average
    }

    private static func solveChainByBoneDirections(
        _ chain: [String],
        targets: Skin3DCanonicalTargetFrame,
        session: SkinnedRigSession
    ) {
        guard chain.count >= 2 else {
            return
        }

        for index in 0..<(chain.count - 1) {
            let parentName = chain[index]
            let childName = chain[index + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let parentTarget = targets.targetsByJoint[parentName],
                  let childTarget = targets.targetsByJoint[childName] else {
                continue
            }

            let targetVector = childTarget.position - parentTarget.position
            let currentVector = childNode.simdWorldPosition - parentNode.simdWorldPosition

            guard simd_length(targetVector) > 0.0001,
                  simd_length(currentVector) > 0.0001 else {
                continue
            }

            let deltaWorld = simd_quatf(
                from: simd_normalize(currentVector),
                to: simd_normalize(targetVector)
            )

            applyWorldRotationDelta(deltaWorld, to: parentNode)
        }
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorld = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorld) * deltaWorld * parentWorld

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func resetBonesToRestOnly(
        session: SkinnedRigSession
    ) {
        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName] else {
                continue
            }

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation
            bone.simdScale = restScale
        }
    }

    private static func makeStats(
        frameIndex: Int,
        targets: Skin3DCanonicalTargetFrame,
        session: SkinnedRigSession,
        alignment: Alignment
    ) -> Stats {
        var total: Float = 0
        var count: Float = 0
        var worstJoint = "none"
        var worst: Float = 0

        for joint in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[joint],
                  let target = targets.targetsByJoint[joint] else {
                continue
            }

            let error = simd_length(bone.simdWorldPosition - target.position)
            total += error
            count += 1

            if error > worst {
                worst = error
                worstJoint = joint
            }
        }

        return Stats(
            frameIndex: frameIndex,
            targetCount: Int(count),
            avgTargetError: count > 0 ? total / count : 0,
            worstJoint: worstJoint,
            worstError: worst,
            alignmentValid: alignment.valid,
            alignmentScale: alignment.scale
        )
    }

    private static func bodyBasis(
        points: [String: SIMD3<Float>]
    ) -> simd_float3x3? {
        guard let hips = points["Hips"] else {
            return nil
        }

        let upper = points["Spine"] ?? points["neck"] ?? points["Head"]
        guard let upper else {
            return nil
        }

        let left = points["LeftArm"] ?? points["LeftShoulder"] ?? points["LeftUpLeg"]
        let right = points["RightArm"] ?? points["RightShoulder"] ?? points["RightUpLeg"]
        guard let left, let right else {
            return nil
        }

        let up = normalizeSafe(
            upper - hips,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let rightAxis = normalizeSafe(
            right - left,
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let forward = normalizeSafe(
            simd_cross(rightAxis, up),
            fallback: SIMD3<Float>(0, 0, 1)
        )
        let cleanRight = normalizeSafe(
            simd_cross(up, forward),
            fallback: rightAxis
        )

        return simd_float3x3(
            cleanRight,
            up,
            forward
        )
    }

    private static func logSkin3DConnectedRetarget(
        frameIndex: Int,
        targets: Skin3DCanonicalTargetFrame,
        session: SkinnedRigSession,
        stats: Stats
    ) {
        print("""
        [Skin3D] CONNECTED RETARGET
          frame: \(frameIndex)
          targetJoints: \(targets.targetsByJoint.count)
          avgError: \(String(format: "%.5f", stats.avgTargetError))
          worst: \(stats.worstJoint)
          worstError: \(String(format: "%.5f", stats.worstError))
          usesConnectedRigEdges: true
          directSetChildWorldPositions: false
          debugSkeletonOnly: false
        """)

        let debugEdges = [
            ("Hips", "Spine02"),
            ("Spine", "neck"),
            ("LeftArm", "LeftForeArm"),
            ("LeftForeArm", "LeftHand"),
            ("RightArm", "RightForeArm"),
            ("RightForeArm", "RightHand"),
            ("LeftUpLeg", "LeftLeg"),
            ("LeftLeg", "LeftFoot"),
            ("RightUpLeg", "RightLeg"),
            ("RightLeg", "RightFoot")
        ]

        for (parent, child) in debugEdges {
            guard let parentNode = session.bonesByCanonicalName[parent],
                  let childNode = session.bonesByCanonicalName[child],
                  let parentTarget = targets.targetsByJoint[parent],
                  let childTarget = targets.targetsByJoint[child] else {
                continue
            }

            let rigDirection = normalizeSafe(
                childNode.simdWorldPosition - parentNode.simdWorldPosition,
                fallback: SIMD3<Float>(0, 1, 0)
            )
            let targetDirection = normalizeSafe(
                childTarget.position - parentTarget.position,
                fallback: SIMD3<Float>(0, 1, 0)
            )
            let clampedDot = max(Float(-1), min(Float(1), simd_dot(rigDirection, targetDirection)))
            let angle = acos(clampedDot)

            print("""
            [Skin3D] edge direction
              edge: \(parent)->\(child)
              angleRadians: \(String(format: "%.4f", angle))
              rigParent: \(parentNode.simdWorldPosition)
              rigChild: \(childNode.simdWorldPosition)
              targetParent: \(parentTarget.position)
              targetChild: \(childTarget.position)
            """)
        }
    }

    private static func center(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else {
            return SIMD3<Float>(0, 0, 0)
        }

        return points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)
    }

    private static func averageRadius(
        _ points: [SIMD3<Float>],
        center: SIMD3<Float>
    ) -> Float {
        guard !points.isEmpty else {
            return 1
        }

        return points
            .map { simd_length($0 - center) }
            .reduce(0, +) / Float(points.count)
    }

    private static func normalizeSafe(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > 0.000001 else {
            return fallback
        }

        return vector / length
    }
}

extension Vision3DSkinningDriver.Alignment {
    static let invalid = Vision3DSkinningDriver.Alignment(
        valid: false,
        scale: 1,
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        translation: SIMD3<Float>(0, 0, 0)
    )

    var state: Vision3DSkinningAlignmentState {
        Vision3DSkinningAlignmentState(
            valid: valid,
            scale: scale,
            rotationWXYZ: [
                rotation.vector.w,
                rotation.vector.x,
                rotation.vector.y,
                rotation.vector.z
            ],
            translationXYZ: [
                translation.x,
                translation.y,
                translation.z
            ]
        )
    }
}

extension Vision3DSkinningAlignmentState {
    var driverAlignment: Vision3DSkinningDriver.Alignment {
        let q = simd_quatf(
            vector: SIMD4<Float>(
                rotationWXYZ.count > 1 ? rotationWXYZ[1] : 0,
                rotationWXYZ.count > 2 ? rotationWXYZ[2] : 0,
                rotationWXYZ.count > 3 ? rotationWXYZ[3] : 0,
                rotationWXYZ.count > 0 ? rotationWXYZ[0] : 1
            )
        )

        let t = SIMD3<Float>(
            translationXYZ.count > 0 ? translationXYZ[0] : 0,
            translationXYZ.count > 1 ? translationXYZ[1] : 0,
            translationXYZ.count > 2 ? translationXYZ[2] : 0
        )

        return Vision3DSkinningDriver.Alignment(
            valid: valid,
            scale: scale,
            rotation: q,
            translation: t
        )
    }
}
