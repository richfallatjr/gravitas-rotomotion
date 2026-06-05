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

struct CurvePinnedSettings {
    var limbPinWiggle: Float = 0.02
    var limbPinPull: Float = 0.65

    var iterations: Int = 8

    static let `default` = CurvePinnedSettings()
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
    static let armChains: [[String]] = [
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"]
    ]

    static let torsoChain: [String] = [
        "Hips",
        "Spine",
        "neck",
        "Head",
        "headfront"
    ]

    static let legSides = [
        "Left",
        "Right"
    ]

    static let solveChains: [[String]] = [
        ["neck", "Head", "headfront"],
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
        ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    ]

    static func rotomateFrameWithCurvePins(
        _ frame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float,
        settings: CurvePinnedSettings = .default
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)

        let rays = JointRayBuilder.buildRays(
            normalizedFrame: normalizedFrame,
            cameraOrigin: cameraOrigin,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        if frame.frameIndex == 0 {
            print(
                """
                [CurvePinnedRotomation] Ordered ray-pinned solve:
                  initial Hips-Spine fit reused: false
                  Hips ray pinned: false
                  Spine static locked: false
                  pelvis driver: LeftUpLeg + RightUpLeg rays
                  displayRoot moved by solve: true
                """
            )
        }

        solvePelvisFromUpperLegRays(
            session: session,
            rays: rays
        )

        solvePinnedJointSequence(
            ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["Hips", "Spine", "neck", "Head", "headfront"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
            rays: rays,
            session: session
        )

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
        resetBonesToRestOnly(session: session)
    }

    private static func resetBonesToRestOnly(session: SkinnedRigSession) {
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

    private static func solvePelvisFromUpperLegRays(
        session: SkinnedRigSession,
        rays: [String: JointRay]
    ) {
        guard let leftHipNode = session.bonesByCanonicalName["LeftUpLeg"],
              let rightHipNode = session.bonesByCanonicalName["RightUpLeg"],
              let hipsNode = session.bonesByCanonicalName["Hips"],
              let leftRay = rays["LeftUpLeg"],
              let rightRay = rays["RightUpLeg"] else {
            return
        }

        let leftCurrent = leftHipNode.simdWorldPosition
        let rightCurrent = rightHipNode.simdWorldPosition

        let leftTarget = closestPointOnRay(
            ray: leftRay,
            to: leftCurrent
        )
        let rightTarget = closestPointOnRay(
            ray: rightRay,
            to: rightCurrent
        )

        let averageDelta = ((leftTarget - leftCurrent) + (rightTarget - rightCurrent)) * 0.5
        session.displayRootNode.simdPosition += averageDelta

        let currentWidth = rightHipNode.simdWorldPosition - leftHipNode.simdWorldPosition
        let targetWidth = rightTarget - leftTarget

        guard simd_length(currentWidth) > 0.0001,
              simd_length(targetWidth) > 0.0001 else {
            return
        }

        let deltaWorld = simd_quatf(
            from: simd_normalize(currentWidth),
            to: simd_normalize(targetWidth)
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: hipsNode
        )
    }

    private static func solvePinnedJointSequence(
        _ chain: [String],
        rays: [String: JointRay],
        session: SkinnedRigSession,
        passes: Int = 4
    ) {
        guard chain.count >= 2 else {
            return
        }

        for _ in 0..<passes {
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
                let childTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    currentChild: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: childTarget
                )
            }
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

    private static func solveTorsoChain(
        rays: [String: JointRay],
        session: SkinnedRigSession
    ) {
        for i in 0..<(torsoChain.count - 1) {
            let parentName = torsoChain[i]
            let childName = torsoChain[i + 1]

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
            let target = pointOnRayAtDistanceFromParent(
                ray: childRay,
                parent: parentWorld,
                distance: boneLength,
                fallback: childWorld
            )

            rotateParentToMoveChild(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: target
            )
        }
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

    private static func solvePoleLockedLeg(
        side: String,
        rays: [String: JointRay],
        session: SkinnedRigSession,
        frameIndex: Int
    ) {
        let hipName = "\(side)UpLeg"
        let kneeName = "\(side)Leg"
        let ankleName = "\(side)Foot"
        let toeName = "\(side)ToeBase"

        guard let hip = session.bonesByCanonicalName[hipName],
              let knee = session.bonesByCanonicalName[kneeName],
              let ankle = session.bonesByCanonicalName[ankleName],
              let ankleRay = rays[ankleName] else {
            return
        }

        let hipWorld = hip.simdWorldPosition
        let kneeWorld = knee.simdWorldPosition
        let ankleWorld = ankle.simdWorldPosition

        let upperLength = max(
            simd_length(kneeWorld - hipWorld),
            0.0001
        )
        let lowerLength = max(
            simd_length(ankleWorld - kneeWorld),
            0.0001
        )
        let restPole = session.restKneePoles[side] ?? normalizeSafe(
            kneeWorld - hipWorld,
            fallback: SIMD3<Float>(0, 0, 1)
        )

        let ankleTarget = closestReachablePointOnRay(
            ray: ankleRay,
            root: hipWorld,
            minDistance: abs(upperLength - lowerLength) + 0.0001,
            maxDistance: upperLength + lowerLength - 0.0001
        )
        let solvedKnee = solveKneeWithRestPole(
            hip: hipWorld,
            ankle: ankleTarget,
            upperLength: upperLength,
            lowerLength: lowerLength,
            restPole: restPole
        )

        if frameIndex == 0 {
            print(
                """
                [CurvePinnedRotomation] \(side) knee pole solve
                  restPole: \(restPole)
                  hip: \(hipWorld)
                  ankleTarget: \(ankleTarget)
                  solvedKnee: \(solvedKnee)
                """
            )
        }

        rotateParentToMoveChild(
            parentNode: hip,
            childNode: knee,
            childTarget: solvedKnee
        )

        rotateParentToMoveChild(
            parentNode: knee,
            childNode: ankle,
            childTarget: ankleTarget
        )

        if let toe = session.bonesByCanonicalName[toeName],
           let toeRay = rays[toeName] {
            let currentFoot = ankle.simdWorldPosition
            let currentToe = toe.simdWorldPosition
            let toeLength = max(
                simd_length(currentToe - currentFoot),
                0.0001
            )
            let toeTarget = pointOnRayAtDistanceFromParent(
                ray: toeRay,
                parent: currentFoot,
                distance: toeLength,
                fallback: currentToe
            )

            rotateParentToMoveChild(
                parentNode: ankle,
                childNode: toe,
                childTarget: toeTarget
            )
        }
    }

    private static func solveKneeWithRestPole(
        hip: SIMD3<Float>,
        ankle: SIMD3<Float>,
        upperLength: Float,
        lowerLength: Float,
        restPole: SIMD3<Float>
    ) -> SIMD3<Float> {
        let hipToAnkleRaw = ankle - hip
        let distance = min(
            max(simd_length(hipToAnkleRaw), abs(upperLength - lowerLength) + 0.0001),
            upperLength + lowerLength - 0.0001
        )
        let direction = normalizeSafe(
            hipToAnkleRaw,
            fallback: SIMD3<Float>(0, -1, 0)
        )
        let x = (
            upperLength * upperLength -
            lowerLength * lowerLength +
            distance * distance
        ) / (2.0 * distance)
        let h = sqrt(max(upperLength * upperLength - x * x, 0.0))
        var pole = restPole - direction * simd_dot(restPole, direction)
        pole = normalizeSafe(
            pole,
            fallback: restPole
        )

        return hip + direction * x + pole * h
    }

    private static func closestReachablePointOnRay(
        ray: JointRay,
        root: SIMD3<Float>,
        minDistance: Float,
        maxDistance: Float
    ) -> SIMD3<Float> {
        let closest = closestPointOnRay(
            ray: ray,
            to: root
        )
        let raw = closest - root
        let distance = simd_length(raw)

        if distance > maxDistance {
            return root + normalizeSafe(
                raw,
                fallback: SIMD3<Float>(0, -1, 0)
            ) * maxDistance
        }

        if distance < minDistance {
            return root + normalizeSafe(
                raw,
                fallback: SIMD3<Float>(0, -1, 0)
            ) * minDistance
        }

        return closest
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

    private static func pointOnRayAtDistanceFromParent(
        ray: JointRay,
        parent: SIMD3<Float>,
        distance: Float,
        currentChild: SIMD3<Float>
    ) -> SIMD3<Float> {
        let origin = ray.origin
        let direction = ray.direction
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
                .map { origin + direction * $0 }

            if let best = candidates.min(by: {
                simd_length_squared($0 - currentChild) < simd_length_squared($1 - currentChild)
            }) {
                return best
            }
        }

        let closest = closestPointOnRay(
            ray: ray,
            to: currentChild
        )
        let childDirection = closest - parent

        guard simd_length(childDirection) > 0.0001 else {
            return currentChild
        }

        return parent + simd_normalize(childDirection) * distance
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
            guard jointName != "Hips" else {
                continue
            }

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

enum StereoTargetRigRotomationDriver {
    static func rotomateFrameWithStereoTargets(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        metersToSceneUnits: Float,
        iterations: Int = 6
    ) {
        let targetScale = max(metersToSceneUnits, 0.0001)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)
        placeRootFromStereoHipsOrUpperLegs(
            frame,
            session: session,
            targetScale: targetScale
        )

        solveChain(
            ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["Hips", "Spine", "neck", "Head", "headfront"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )

        SCNTransaction.commit()
        logFitError(
            frame,
            session: session,
            targetScale: targetScale
        )
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

    private static func placeRootFromStereoHipsOrUpperLegs(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float
    ) {
        let targetNames = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var deltas: [SIMD3<Float>] = []

        for name in targetNames {
            guard let bone = session.bonesByCanonicalName[name],
                  let target = stereoPosition(
                    name,
                    in: frame,
                    targetScale: targetScale
                  ) else {
                continue
            }

            deltas.append(target - bone.simdWorldPosition)
        }

        guard !deltas.isEmpty else {
            return
        }

        let average = deltas.reduce(
            SIMD3<Float>(0, 0, 0),
            +
        ) / Float(deltas.count)

        session.displayRootNode.simdPosition += average
    }

    private static func solveChain(
        _ chain: [String],
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float,
        passes: Int = 4
    ) {
        guard chain.count >= 2 else {
            return
        }

        for _ in 0..<passes {
            for i in 0..<(chain.count - 1) {
                let parentName = chain[i]
                let childName = chain[i + 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childTarget = stereoPosition(
                        childName,
                        in: frame,
                        targetScale: targetScale
                      ) else {
                    continue
                }

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: childTarget
                )
            }
        }
    }

    private static func stereoPosition(
        _ joint: String,
        in frame: StereoMeshyJointCapture.Frame,
        targetScale: Float
    ) -> SIMD3<Float>? {
        guard let target = frame.joints[joint],
              target.validStereo,
              target.positionCameraXYZ.count == 3 else {
            return nil
        }

        return SIMD3<Float>(
            Float(target.positionCameraXYZ[0]),
            Float(target.positionCameraXYZ[1]),
            Float(target.positionCameraXYZ[2])
        ) * targetScale
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

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000001 else {
            return fallback
        }

        return value / length
    }

    private static func logFitError(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float
    ) {
        var worstJoint = "none"
        var worstError: Float = 0
        var averageError: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = stereoPosition(
                    jointName,
                    in: frame,
                    targetScale: targetScale
                  ) else {
                continue
            }

            let error = simd_length(
                bone.simdWorldPosition - target
            )
            averageError += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        guard count > 0,
              frame.frameIndex == 0 || frame.frameIndex % 30 == 0 else {
            return
        }

        averageError /= count

        print("""
        [StereoTargetRigRotomation] fit error
          frame: \(frame.frameIndex)
          avgPositionError: \(averageError)
          worstJoint: \(worstJoint)
          worstError: \(worstError)
          metersToSceneUnits: \(targetScale)
        """)
    }
}
