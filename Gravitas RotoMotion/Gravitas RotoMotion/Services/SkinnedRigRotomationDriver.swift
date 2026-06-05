import Foundation
import CoreGraphics
import SceneKit
import simd

struct JointRay {
    let jointName: String
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>

    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

enum JointRayBuilder {
    static func buildRays(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) -> [String: JointRay] {
        var rays: [String: JointRay] = [:]

        for (jointName, joint) in normalizedFrame.joints {
            guard !joint.missing else {
                continue
            }

            let planePoint = SIMD3<Float>(
                (Float(joint.x) - 0.5) * Float(videoPlaneSize.width),
                (Float(joint.y) - 0.5) * Float(videoPlaneSize.height),
                videoPlaneZ
            )

            let direction = normalizeSafe(planePoint - cameraOrigin)

            rays[jointName] = JointRay(
                jointName: jointName,
                origin: cameraOrigin,
                direction: direction
            )
        }

        return rays
    }

    private static func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.000001 else {
            return SIMD3<Float>(0, 0, -1)
        }

        return v / len
    }
}

enum SkinnedRigRotomationDriver {
    static let baseChain = ["Hips", "Spine"]

    static let limbsOutsideIn: [[String]] = [
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
        ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    ]

    static let solveChains: [[String]] = [
        ["Hips", "Spine", "neck", "Head"],

        ["Spine", "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["Spine", "RightShoulder", "RightArm", "RightForeArm", "RightHand"],

        ["Hips", "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["Hips", "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    ]

    static func rotomateFrameWithCurvePins(
        _ frame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetToRest(session: session)

        let rays = JointRayBuilder.buildRays(
            normalizedFrame: normalizedFrame,
            cameraOrigin: cameraOrigin,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        lockBaseHipsSpine(
            session: session,
            rays: rays
        )

        for chain in limbsOutsideIn {
            solvePinnedLimbOutsideIn(
                chain: chain,
                rays: rays,
                session: session,
                iterations: 8
            )
        }

        SCNTransaction.commit()

        logPinnedFitError(
            session: session,
            rays: rays,
            frameIndex: frame.frameIndex
        )
    }

    static func rotomateFrame(
        _ frame: RotoRayAnimationSolveResult.Frame,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        iterations: Int = 12
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetToRest(session: session)
        lockBase(
            session: session,
            targets: frame.jointPositions
        )

        for _ in 0..<iterations {
            for chain in solveChains {
                solveChainToPositions(
                    chain,
                    targets: frame.jointPositions,
                    session: session,
                    cameraOrigin: cameraOrigin
                )
            }
        }

        SCNTransaction.commit()

        logFitError(
            frame: frame,
            session: session
        )
    }

    static func resetToRest(session: SkinnedRigSession) {
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

    static func logActualRigPositionError(
        session: SkinnedRigSession,
        frame: RotoRayAnimationSolveResult.Frame
    ) {
        logFitError(
            frame: frame,
            session: session,
            force: true
        )
    }

    private static func lockBaseHipsSpine(
        session: SkinnedRigSession,
        rays: [String: JointRay]
    ) {
        guard let hips = session.bonesByCanonicalName["Hips"],
              let spine = session.bonesByCanonicalName["Spine"],
              let spineRay = rays["Spine"] else {
            return
        }

        let hipsWorld = hips.simdWorldPosition
        let spineWorld = spine.simdWorldPosition
        let length = max(
            simd_length(spineWorld - hipsWorld),
            0.0001
        )

        let spineTarget = pointOnRayAtDistanceFromParent(
            ray: spineRay,
            parent: hipsWorld,
            distance: length,
            fallback: spineWorld
        )

        rotateParentToMoveChild(
            parentNode: hips,
            childNode: spine,
            childTarget: spineTarget
        )
    }

    private static func solvePinnedLimbOutsideIn(
        chain: [String],
        rays: [String: JointRay],
        session: SkinnedRigSession,
        iterations: Int = 8
    ) {
        guard chain.count >= 3 else {
            return
        }

        for _ in 0..<iterations {
            for i in stride(from: chain.count - 1, through: 1, by: -1) {
                let childName = chain[i]
                let parentName = chain[i - 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childRay = rays[childName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )

                let pinnedTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    fallback: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: pinnedTarget
                )
            }

            for i in 0..<(chain.count - 1) {
                let parentName = chain[i]
                let childName = chain[i + 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childRay = rays[childName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )

                let pinnedTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    fallback: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: pinnedTarget
                )
            }
        }
    }

    private static func rotateParentToMoveChild(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition

        let current = normalizeSafe(
            childWorld - parentWorld,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let target = normalizeSafe(
            childTarget - parentWorld,
            fallback: current
        )

        let deltaWorld = simd_quatf(
            from: current,
            to: target
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func closestPointOnRay(
        ray: JointRay,
        to point: SIMD3<Float>
    ) -> SIMD3<Float> {
        let t = max(
            0,
            simd_dot(point - ray.origin, ray.direction)
        )

        return ray.point(at: t)
    }

    private static func pointOnRayAtDistanceFromParent(
        ray: JointRay,
        parent: SIMD3<Float>,
        distance: Float,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let direction = ray.direction
        let origin = ray.origin
        let offset = origin - parent

        let a = simd_dot(direction, direction)
        let b = 2.0 * simd_dot(offset, direction)
        let c = simd_dot(offset, offset) - distance * distance
        let discriminant = b * b - 4.0 * a * c

        if discriminant >= 0 {
            let root = sqrt(discriminant)
            let t0 = (-b - root) / (2.0 * a)
            let t1 = (-b + root) / (2.0 * a)

            let candidates = [t0, t1]
                .filter { $0.isFinite && $0 >= 0 }
                .map { ray.point(at: $0) }

            if let best = candidates.min(by: {
                simd_length_squared($0 - fallback) < simd_length_squared($1 - fallback)
            }) {
                return best
            }
        }

        let closest = closestPointOnRay(
            ray: ray,
            to: parent
        )

        let directionToRay = normalizeSafe(
            closest - parent,
            fallback: fallback - parent
        )

        return parent + directionToRay * distance
    }

    private static func logPinnedFitError(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        frameIndex: Int
    ) {
        var worst = "none"
        var worstError: Float = 0
        var sum: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName] else {
                continue
            }

            let point = bone.simdWorldPosition
            let closest = closestPointOnRay(
                ray: ray,
                to: point
            )
            let error = simd_length(point - closest)

            sum += error
            count += 1

            if error > worstError {
                worstError = error
                worst = jointName
            }
        }

        if frameIndex == 0 || frameIndex % 30 == 0 {
            print(
                """
                [CurvePinnedRotomation] fit error
                  frame: \(frameIndex)
                  avgRayDistance: \(String(format: "%.5f", count > 0 ? sum / count : 0))
                  worst: \(worst)
                  worstRayDistance: \(String(format: "%.5f", worstError))
                """
            )
        }
    }

    private static func lockBase(
        session: SkinnedRigSession,
        targets: [String: SIMD3<Float>]
    ) {
        guard let hips = session.bonesByCanonicalName["Hips"],
              let spine = session.bonesByCanonicalName["Spine"],
              let hipsTarget = targets["Hips"],
              let spineTarget = targets["Spine"] else {
            return
        }

        let current = normalizeSafe(
            spine.simdWorldPosition - hips.simdWorldPosition,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let target = normalizeSafe(
            spineTarget - hipsTarget,
            fallback: current
        )

        let deltaWorld = simd_quatf(
            from: current,
            to: target
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: hips
        )
    }

    private static func solveChainToPositions(
        _ chain: [String],
        targets: [String: SIMD3<Float>],
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>
    ) {
        guard chain.count >= 2 else {
            return
        }

        for i in 0..<(chain.count - 1) {
            let parentName = chain[i]
            let childName = chain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let childTarget = targets[childName] else {
                continue
            }

            rotateParentTowardChildTarget(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: childTarget,
                cameraOrigin: cameraOrigin
            )
        }
    }

    private static func rotateParentTowardChildTarget(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition
        let boneLength = max(
            simd_length(childWorld - parentWorld),
            0.0001
        )

        let adjustedTarget = bestTargetNearRay(
            originalTarget: childTarget,
            cameraOrigin: cameraOrigin,
            maxZOffset: 2.0,
            samples: 17,
            score: { candidate in
                abs(simd_length(candidate - parentWorld) - boneLength)
            }
        )

        let currentVector = normalizeSafe(
            childWorld - parentWorld,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let targetVector = normalizeSafe(
            adjustedTarget - parentWorld,
            fallback: currentVector
        )

        let deltaWorld = simd_quatf(
            from: currentVector,
            to: targetVector
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func bestTargetNearRay(
        originalTarget: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>,
        maxZOffset: Float = 2.0,
        samples: Int = 17,
        score: (SIMD3<Float>) -> Float
    ) -> SIMD3<Float> {
        let rayDir = normalizeSafe(
            originalTarget - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        var best = originalTarget
        var bestScore = score(originalTarget)

        for i in 0..<samples {
            let t = Float(i) / Float(max(samples - 1, 1))
            let offset = -maxZOffset + 2.0 * maxZOffset * t
            let candidate = originalTarget + rayDir * offset
            let candidateScore = score(candidate)

            if candidateScore < bestScore {
                bestScore = candidateScore
                best = candidate
            }
        }

        return best
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorldRotation = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorldRotation) * deltaWorld * parentWorldRotation

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func logFitError(
        frame: RotoRayAnimationSolveResult.Frame,
        session: SkinnedRigSession,
        force: Bool = false
    ) {
        var worstJoint = "none"
        var worstError: Float = 0
        var averageError: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = frame.jointPositions[jointName] else {
                continue
            }

            let error = simd_length(bone.simdWorldPosition - target)
            averageError += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        let avgError = count > 0 ? averageError / count : 0

        if force || frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
            print(
                """
                [SkinnedRigRotomationDriver] position fit error
                  frame: \(frame.frameIndex)
                  avgError: \(String(format: "%.5f", avgError))
                  worstJoint: \(worstJoint)
                  worstError: \(String(format: "%.5f", worstError))
                """
            )
        }
    }

    private static func normalizeSafe(
        _ v: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.000001 else {
            return fallback
        }

        return v / len
    }
}
