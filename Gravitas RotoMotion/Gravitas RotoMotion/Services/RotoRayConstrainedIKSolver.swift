import CoreGraphics
import Foundation
import simd

enum RotoRayConstrainedIKSolver {
    enum Mode {
        case spineOnly
        case fullBody
    }

    struct Settings: Equatable {
        var maxIterations = 16
        var epsilon: Float = 0.0005
        var midRayPull: Float = 0.35
        var polePull: Float = 0.45
        var previousFramePull: Float = 0.18
        var confidenceMinimum: Float = 0.01

        static let `default` = Settings()
    }

    static func solve(
        frame: NormalizedMeshyPoseCapture.Frame,
        armature: RotoReferenceArmature = .meshy24Default,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float = 0,
        mode: Mode,
        previousFramePositions: [String: SIMD3<Float>]?,
        settings: Settings = .default
    ) -> RotoRayIKSolveResult {
        let rays = RotoCameraRayBuilder.buildRays(
            normalizedFrame: frame,
            cameraOrigin: cameraOrigin,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        let jointByName = armature.jointByName
        var jointPositions: [String: SIMD3<Float>] = [:]
        var solved = Set<String>()
        var missing = Set<String>()
        var errors: [String: Float] = [:]

        solveRoot(
            rays: rays,
            previousFramePositions: previousFramePositions,
            jointPositions: &jointPositions,
            solved: &solved,
            missing: &missing,
            videoPlaneZ: videoPlaneZ
        )

        solveSingleRayChain(
            ["Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "head_end", "headfront"],
            rays: rays,
            jointByName: jointByName,
            previousFramePositions: previousFramePositions,
            jointPositions: &jointPositions,
            solved: &solved,
            missing: &missing,
            errors: &errors,
            settings: settings
        )

        if mode == .fullBody {
            solveBridgeJoint(
                jointName: "LeftShoulder",
                parentName: "Spine",
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                settings: settings
            )

            solveBridgeJoint(
                jointName: "RightShoulder",
                parentName: "Spine",
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                settings: settings
            )

            solveIterativeTwoBoneLimb(
                rootName: "LeftShoulder",
                midName: "LeftArm",
                endName: "LeftForeArm",
                targetName: "LeftHand",
                pole: SIMD3<Float>(0, 0, 1),
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                errors: &errors,
                settings: settings
            )

            solveIterativeTwoBoneLimb(
                rootName: "RightShoulder",
                midName: "RightArm",
                endName: "RightForeArm",
                targetName: "RightHand",
                pole: SIMD3<Float>(0, 0, 1),
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                errors: &errors,
                settings: settings
            )

            solveBridgeJoint(
                jointName: "LeftUpLeg",
                parentName: "Hips",
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                settings: settings
            )

            solveBridgeJoint(
                jointName: "RightUpLeg",
                parentName: "Hips",
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                settings: settings
            )

            solveIterativeTwoBoneLimb(
                rootName: "LeftUpLeg",
                midName: "LeftLeg",
                endName: "LeftFoot",
                targetName: "LeftToeBase",
                pole: SIMD3<Float>(0, 0, 1),
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                errors: &errors,
                settings: settings
            )

            solveIterativeTwoBoneLimb(
                rootName: "RightUpLeg",
                midName: "RightLeg",
                endName: "RightFoot",
                targetName: "RightToeBase",
                pole: SIMD3<Float>(0, 0, 1),
                rays: rays,
                jointByName: jointByName,
                previousFramePositions: previousFramePositions,
                jointPositions: &jointPositions,
                solved: &solved,
                missing: &missing,
                errors: &errors,
                settings: settings
            )
        }

        let rotations = RotoSolvedPoseRotationBuilder.buildLocalRotationsWXYZ(
            armature: armature,
            jointPositions: jointPositions
        )

        return RotoRayIKSolveResult(
            frameIndex: frame.frameIndex,
            timeSeconds: frame.timeSeconds,
            jointPositions: jointPositions,
            localRotationsWXYZ: rotations,
            projectionErrors: errors,
            solvedJoints: solved,
            missingJoints: missing
        )
    }

    private static func solveRoot(
        rays: [String: RotoCameraRay],
        previousFramePositions: [String: SIMD3<Float>]?,
        jointPositions: inout [String: SIMD3<Float>],
        solved: inout Set<String>,
        missing: inout Set<String>,
        videoPlaneZ: Float
    ) {
        if let ray = rays["Hips"] {
            let p = rayPlaneZIntersection(ray: ray, z: videoPlaneZ)

            if let previous = previousFramePositions?["Hips"] {
                jointPositions["Hips"] = mix(previous, p, 0.75)
            } else {
                jointPositions["Hips"] = p
            }

            solved.insert("Hips")
        } else if let previous = previousFramePositions?["Hips"] {
            jointPositions["Hips"] = previous
            missing.insert("Hips")
        } else {
            jointPositions["Hips"] = SIMD3<Float>(0, 0, videoPlaneZ)
            missing.insert("Hips")
        }
    }

    private static func solveSingleRayChain(
        _ chain: [String],
        rays: [String: RotoCameraRay],
        jointByName: [String: RotoReferenceArmature.Joint],
        previousFramePositions: [String: SIMD3<Float>]?,
        jointPositions: inout [String: SIMD3<Float>],
        solved: inout Set<String>,
        missing: inout Set<String>,
        errors: inout [String: Float],
        settings: Settings
    ) {
        guard chain.count >= 2 else { return }

        for index in 1..<chain.count {
            let parentName = chain[index - 1]
            let jointName = chain[index]

            guard let parentPosition = jointPositions[parentName],
                  let joint = jointByName[jointName] else {
                missing.insert(jointName)
                continue
            }

            let length = max(Float(joint.boneLengthToParent), 0.0001)
            let position: SIMD3<Float>

            if let ray = rays[jointName] {
                var p = pointOnRayAtDistanceFromParent(
                    ray: ray,
                    parent: parentPosition,
                    distance: length,
                    fallbackDirection: fallbackDirection(for: jointName)
                )

                if let previous = previousFramePositions?[jointName] {
                    p = preserveBoneLength(
                        candidate: mix(previous, p, 1.0 - settings.previousFramePull),
                        parent: parentPosition,
                        length: length,
                        fallback: p - parentPosition
                    )
                }

                position = p
                solved.insert(jointName)
                errors[jointName] = distanceFromPointToRay(position, ray: ray)
            } else if let previous = previousFramePositions?[jointName] {
                position = preserveBoneLength(
                    candidate: previous,
                    parent: parentPosition,
                    length: length,
                    fallback: fallbackDirection(for: jointName)
                )
                missing.insert(jointName)
            } else {
                position = parentPosition + fallbackDirection(for: jointName) * length
                missing.insert(jointName)
            }

            jointPositions[jointName] = position
        }
    }

    private static func solveBridgeJoint(
        jointName: String,
        parentName: String,
        rays: [String: RotoCameraRay],
        jointByName: [String: RotoReferenceArmature.Joint],
        previousFramePositions: [String: SIMD3<Float>]?,
        jointPositions: inout [String: SIMD3<Float>],
        solved: inout Set<String>,
        missing: inout Set<String>,
        settings: Settings
    ) {
        guard let parent = jointPositions[parentName],
              let joint = jointByName[jointName] else {
            missing.insert(jointName)
            return
        }

        let length = max(Float(joint.boneLengthToParent), 0.0001)
        let candidate: SIMD3<Float>

        if let ray = rays[jointName] {
            candidate = pointOnRayAtDistanceFromParent(
                ray: ray,
                parent: parent,
                distance: length,
                fallbackDirection: fallbackDirection(for: jointName)
            )
            solved.insert(jointName)
        } else if let previous = previousFramePositions?[jointName] {
            candidate = previous
            missing.insert(jointName)
        } else {
            candidate = parent + fallbackDirection(for: jointName) * length
            missing.insert(jointName)
        }

        jointPositions[jointName] = preserveBoneLength(
            candidate: candidate,
            parent: parent,
            length: length,
            fallback: fallbackDirection(for: jointName)
        )
    }

    private static func solveIterativeTwoBoneLimb(
        rootName: String,
        midName: String,
        endName: String,
        targetName: String,
        pole: SIMD3<Float>,
        rays: [String: RotoCameraRay],
        jointByName: [String: RotoReferenceArmature.Joint],
        previousFramePositions: [String: SIMD3<Float>]?,
        jointPositions: inout [String: SIMD3<Float>],
        solved: inout Set<String>,
        missing: inout Set<String>,
        errors: inout [String: Float],
        settings: Settings
    ) {
        guard let root = jointPositions[rootName],
              let midJoint = jointByName[midName],
              let endJoint = jointByName[endName],
              let endRay = rays[targetName] else {
            missing.insert(midName)
            missing.insert(endName)
            return
        }

        let upperLength = max(Float(midJoint.boneLengthToParent), 0.0001)
        let lowerLength = max(Float(endJoint.boneLengthToParent), 0.0001)
        let midRay = rays[midName]

        var end = closestReachablePointOnRay(
            ray: endRay,
            root: root,
            minDistance: abs(upperLength - lowerLength) + 0.0001,
            maxDistance: upperLength + lowerLength - 0.0001
        )

        if let previousEnd = previousFramePositions?[endName] {
            end = mix(previousEnd, end, 1.0 - settings.previousFramePull)
        }

        var mid = solveMidFromRootEndPole(
            root: root,
            end: end,
            upperLength: upperLength,
            lowerLength: lowerLength,
            pole: pole
        )

        if let previousMid = previousFramePositions?[midName] {
            mid = preserveBoneLength(
                candidate: mix(previousMid, mid, 1.0 - settings.previousFramePull),
                parent: root,
                length: upperLength,
                fallback: mid - root
            )
        }

        var lastError = Float.greatestFiniteMagnitude

        for _ in 0..<settings.maxIterations {
            if let midRay {
                let preferredMid = closestPointOnRay(
                    to: mid,
                    ray: midRay
                )
                mid = preserveBoneLength(
                    candidate: mix(mid, preferredMid, settings.midRayPull),
                    parent: root,
                    length: upperLength,
                    fallback: mid - root
                )
            }

            end = pointOnRayAtDistanceFromParent(
                ray: endRay,
                parent: mid,
                distance: lowerLength,
                fallbackDirection: end - mid
            )

            let poleMid = solveMidFromRootEndPole(
                root: root,
                end: end,
                upperLength: upperLength,
                lowerLength: lowerLength,
                pole: pole
            )

            mid = preserveBoneLength(
                candidate: mix(mid, poleMid, settings.polePull),
                parent: root,
                length: upperLength,
                fallback: mid - root
            )

            end = preserveBoneLength(
                candidate: end,
                parent: mid,
                length: lowerLength,
                fallback: end - mid
            )

            let error = distanceFromPointToRay(end, ray: endRay)

            if abs(lastError - error) < settings.epsilon {
                break
            }

            lastError = error
        }

        jointPositions[midName] = mid
        jointPositions[endName] = end

        solved.insert(midName)
        solved.insert(endName)

        errors[endName] = distanceFromPointToRay(end, ray: endRay)

        if let midRay {
            errors[midName] = distanceFromPointToRay(mid, ray: midRay)
        }
    }

    private static func solveMidFromRootEndPole(
        root: SIMD3<Float>,
        end: SIMD3<Float>,
        upperLength: Float,
        lowerLength: Float,
        pole: SIMD3<Float>
    ) -> SIMD3<Float> {
        let rootToEndRaw = end - root
        let distanceRaw = simd_length(rootToEndRaw)
        let distance = min(
            max(distanceRaw, abs(upperLength - lowerLength) + 0.0001),
            upperLength + lowerLength - 0.0001
        )

        let direction = normalizeSafe(
            rootToEndRaw,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let x = (upperLength * upperLength - lowerLength * lowerLength + distance * distance) / (2 * distance)
        let h = sqrt(max(upperLength * upperLength - x * x, 0))
        var poleDir = pole - direction * simd_dot(pole, direction)
        poleDir = normalizeSafe(
            poleDir,
            fallback: SIMD3<Float>(0, 0, 1)
        )

        return root + direction * x + poleDir * h
    }

    private static func closestReachablePointOnRay(
        ray: RotoCameraRay,
        root: SIMD3<Float>,
        minDistance: Float,
        maxDistance: Float
    ) -> SIMD3<Float> {
        let closest = closestPointOnRay(to: root, ray: ray)
        let raw = closest - root
        let dist = simd_length(raw)

        if dist > maxDistance {
            return root + normalizeSafe(raw, fallback: SIMD3<Float>(0, 1, 0)) * maxDistance
        }

        if dist < minDistance {
            return root + normalizeSafe(raw, fallback: SIMD3<Float>(0, 1, 0)) * minDistance
        }

        return closest
    }

    private static func pointOnRayAtDistanceFromParent(
        ray: RotoCameraRay,
        parent: SIMD3<Float>,
        distance: Float,
        fallbackDirection: SIMD3<Float>
    ) -> SIMD3<Float> {
        let direction = ray.direction
        let oc = ray.origin - parent
        let a = simd_dot(direction, direction)
        let b = 2 * simd_dot(oc, direction)
        let c = simd_dot(oc, oc) - distance * distance
        let discriminant = b * b - 4 * a * c

        if discriminant >= 0 {
            let sqrtDisc = sqrt(discriminant)
            let t0 = (-b - sqrtDisc) / (2 * a)
            let t1 = (-b + sqrtDisc) / (2 * a)
            let candidates = [t0, t1]
                .filter { $0.isFinite && $0 >= 0 }
                .map { ray.origin + direction * $0 }

            if let best = candidates.min(by: {
                simd_length_squared($0 - parent) < simd_length_squared($1 - parent)
            }) {
                return best
            }
        }

        let closest = closestPointOnRay(to: parent, ray: ray)
        let constrainedDirection = normalizeSafe(
            closest - parent,
            fallback: fallbackDirection
        )

        return parent + constrainedDirection * distance
    }

    private static func closestPointOnRay(
        to point: SIMD3<Float>,
        ray: RotoCameraRay
    ) -> SIMD3<Float> {
        let t = max(0, simd_dot(point - ray.origin, ray.direction))
        return ray.origin + ray.direction * t
    }

    private static func preserveBoneLength(
        candidate: SIMD3<Float>,
        parent: SIMD3<Float>,
        length: Float,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let direction = normalizeSafe(
            candidate - parent,
            fallback: normalizeSafe(fallback, fallback: SIMD3<Float>(0, 1, 0))
        )

        return parent + direction * length
    }

    private static func rayPlaneZIntersection(
        ray: RotoCameraRay,
        z: Float
    ) -> SIMD3<Float> {
        let denominator = ray.direction.z

        guard abs(denominator) > 0.000001 else {
            return ray.origin + ray.direction
        }

        let t = (z - ray.origin.z) / denominator
        return ray.origin + ray.direction * max(t, 0)
    }

    private static func distanceFromPointToRay(
        _ point: SIMD3<Float>,
        ray: RotoCameraRay
    ) -> Float {
        let closest = closestPointOnRay(to: point, ray: ray)
        return simd_length(point - closest)
    }

    private static func fallbackDirection(
        for jointName: String
    ) -> SIMD3<Float> {
        if jointName.contains("Left") {
            return SIMD3<Float>(-1, 0, 0)
        }

        if jointName.contains("Right") {
            return SIMD3<Float>(1, 0, 0)
        }

        if jointName.contains("Leg") || jointName.contains("Foot") || jointName.contains("Toe") {
            return SIMD3<Float>(0, -1, 0)
        }

        return SIMD3<Float>(0, 1, 0)
    }

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard simd_length_squared(value) > 0.0000001 else {
            return fallback
        }

        return simd_normalize(value)
    }

    private static func mix(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ t: Float
    ) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
