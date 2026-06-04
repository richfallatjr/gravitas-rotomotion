import CoreGraphics
import Foundation
import simd

enum RotoRayRigSolver {
    static let defaultRayLength: Float = 1000.0

    static let spineOrder: [String] = [
        "Hips",
        "Spine02",
        "Spine01",
        "Spine",
        "neck",
        "Head",
        "head_end",
        "headfront"
    ]

    static let fullBodyOrder: [String] = [
        "Hips",
        "Spine02",
        "Spine01",
        "Spine",
        "neck",
        "Head",
        "head_end",
        "headfront",
        "LeftShoulder",
        "LeftArm",
        "LeftForeArm",
        "LeftHand",
        "RightShoulder",
        "RightArm",
        "RightForeArm",
        "RightHand",
        "LeftUpLeg",
        "LeftLeg",
        "LeftFoot",
        "LeftToeBase",
        "RightUpLeg",
        "RightLeg",
        "RightFoot",
        "RightToeBase"
    ]

    enum SolveMode {
        case spineOnly
        case fullBody
    }

    static func solveFrame(
        frameIndex: Int,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        armature: RotoReferenceArmature,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float,
        solveMode: SolveMode,
        rayLength: Float = defaultRayLength
    ) -> RotoRaySolveResult {
        let order = solveMode == .spineOnly ? spineOrder : fullBodyOrder
        let jointMap = armature.jointByName

        var rays: [String: RotoRaySolveResult.CameraRay] = [:]
        var solved: [String: RotoRaySolveResult.SolvedJoint] = [:]
        var errors: [String: Double] = [:]

        for jointName in CanonicalRig.jointNames {
            guard let joint = normalizedFrame.joints[jointName],
                  !joint.missing else {
                continue
            }

            let pointOnPlane = pointOnVideoPlane(
                x: joint.x,
                y: joint.y,
                videoPlaneSize: videoPlaneSize,
                videoPlaneZ: videoPlaneZ
            )

            let direction = normalizeSafe(
                pointOnPlane - cameraOrigin,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            rays[jointName] = .init(
                jointName: jointName,
                origin: cameraOrigin,
                direction: direction,
                length: rayLength
            )
        }

        for jointName in order {
            guard let rigJoint = jointMap[jointName] else {
                continue
            }

            if jointName == "Hips" {
                let hipsPosition: SIMD3<Float>

                if let hipsRay = rays["Hips"] {
                    hipsPosition = closestPointOnRayToPlaneZ(
                        ray: hipsRay,
                        z: videoPlaneZ
                    )
                } else {
                    hipsPosition = SIMD3<Float>(0, 0, videoPlaneZ)
                }

                solved[jointName] = .init(
                    name: jointName,
                    parent: nil,
                    worldPosition: hipsPosition,
                    solved: true,
                    note: "Root solved from Hips ray."
                )
                continue
            }

            guard let parentName = rigJoint.parent,
                  let parentSolved = solved[parentName] else {
                solved[jointName] = .init(
                    name: jointName,
                    parent: rigJoint.parent,
                    worldPosition: fallbackWorldPosition(
                        joint: rigJoint,
                        solved: solved
                    ),
                    solved: false,
                    note: "Parent not solved; used fallback."
                )
                continue
            }

            let length = max(Float(rigJoint.boneLengthToParent), 0.0001)
            let parentPosition = parentSolved.worldPosition

            if let ray = rays[jointName] {
                let chosen = pointOnRayAtDistanceFromParent(
                    rayOrigin: ray.origin,
                    rayDirection: ray.direction,
                    parent: parentPosition,
                    distance: length,
                    fallbackDirection: fallbackDirectionForJoint(jointName)
                )

                solved[jointName] = .init(
                    name: jointName,
                    parent: parentName,
                    worldPosition: chosen,
                    solved: true,
                    note: "Solved by sphere/ray constraint."
                )

                errors[jointName] = reprojectionError(
                    worldPoint: chosen,
                    targetRay: ray
                )
            } else {
                let fallback = parentPosition + fallbackDirectionForJoint(jointName) * length

                solved[jointName] = .init(
                    name: jointName,
                    parent: parentName,
                    worldPosition: fallback,
                    solved: false,
                    note: "Missing ray; used rest/fallback direction."
                )
            }
        }

        return RotoRaySolveResult(
            frameIndex: frameIndex,
            joints: solved,
            rays: rays,
            errors: errors
        )
    }

    private static func pointOnVideoPlane(
        x: Double,
        y: Double,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) -> SIMD3<Float> {
        let px = (CGFloat(x) - 0.5) * videoPlaneSize.width
        let py = (CGFloat(y) - 0.5) * videoPlaneSize.height

        return SIMD3<Float>(
            Float(px),
            Float(py),
            videoPlaneZ
        )
    }

    private static func closestPointOnRayToPlaneZ(
        ray: RotoRaySolveResult.CameraRay,
        z: Float
    ) -> SIMD3<Float> {
        let denominator = ray.direction.z

        if abs(denominator) < 0.000001 {
            return ray.origin + ray.direction
        }

        let t = (z - ray.origin.z) / denominator
        return ray.origin + ray.direction * max(t, 0)
    }

    private static func pointOnRayAtDistanceFromParent(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        parent: SIMD3<Float>,
        distance: Float,
        fallbackDirection: SIMD3<Float>
    ) -> SIMD3<Float> {
        let direction = normalizeSafe(
            rayDirection,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let oc = rayOrigin - parent
        let a = simd_dot(direction, direction)
        let b = 2.0 * simd_dot(oc, direction)
        let c = simd_dot(oc, oc) - distance * distance
        let discriminant = b * b - 4.0 * a * c

        if discriminant >= 0 {
            let sqrtDisc = sqrt(discriminant)
            let t0 = (-b - sqrtDisc) / (2.0 * a)
            let t1 = (-b + sqrtDisc) / (2.0 * a)
            let candidates = [t0, t1]
                .filter { $0.isFinite && $0 >= 0 }
                .map { rayOrigin + direction * $0 }

            if let best = candidates.min(by: {
                lengthSquared($0 - parent) < lengthSquared($1 - parent)
            }) {
                return best
            }
        }

        let tClosest = max(0, simd_dot(parent - rayOrigin, direction))
        let closest = rayOrigin + direction * tClosest
        let constrainedDirection = normalizeSafe(
            closest - parent,
            fallback: fallbackDirection
        )

        return parent + constrainedDirection * distance
    }

    static func closestPointOnRay(
        to worldPoint: SIMD3<Float>,
        ray: RotoRaySolveResult.CameraRay
    ) -> SIMD3<Float> {
        let t = max(0, simd_dot(worldPoint - ray.origin, ray.direction))
        return ray.origin + ray.direction * t
    }

    private static func reprojectionError(
        worldPoint: SIMD3<Float>,
        targetRay: RotoRaySolveResult.CameraRay
    ) -> Double {
        let closest = closestPointOnRay(to: worldPoint, ray: targetRay)
        return Double(simd_length(worldPoint - closest))
    }

    private static func fallbackWorldPosition(
        joint: RotoReferenceArmature.Joint,
        solved: [String: RotoRaySolveResult.SolvedJoint]
    ) -> SIMD3<Float> {
        guard let parent = joint.parent,
              let parentSolved = solved[parent] else {
            return joint.restLocalPosition.simdFloat
        }

        return parentSolved.worldPosition + joint.restLocalPosition.simdFloat
    }

    private static func fallbackDirectionForJoint(
        _ jointName: String
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
        guard lengthSquared(value) > 0.0000001 else {
            return fallback
        }

        return simd_normalize(value)
    }

    private static func lengthSquared(_ value: SIMD3<Float>) -> Float {
        simd_dot(value, value)
    }
}
