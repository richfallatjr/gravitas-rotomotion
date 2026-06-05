import CoreGraphics
import Foundation
import simd

enum RigFitMode: String, CaseIterable, Codable {
    case fullBody
    case upperBody
    case headNeck
    case armsOnly
    case legsOnly
}

struct RigFitSettings: Codable, Equatable {
    var useSmoothedTargets: Bool
    var fitMode: RigFitMode
    var targetWeight: Double
    var previousFrameWeight: Double
    var useGroundConstraint: Bool
    var footContactToleranceMeters: Double

    static let `default` = RigFitSettings(
        useSmoothedTargets: true,
        fitMode: .fullBody,
        targetWeight: 1.0,
        previousFrameWeight: 0.15,
        useGroundConstraint: true,
        footContactToleranceMeters: 0.04
    )
}

enum ConstrainedRigFitter {
    private static let minimumTargetConfidence = 0.05
    private static let groundContactJoints = [
        "LeftFoot",
        "LeftToeBase",
        "RightFoot",
        "RightToeBase"
    ]

    static func fit(
        normalized: NormalizedMeshyPoseCapture,
        smoothed: SmoothedMeshyPoseCapture?,
        rigProfile: RigProfile,
        settings: RigFitSettings,
        groundPlane: GroundPlaneController?
    ) -> RigFitResult {
        var previousFramePositions: [String: SIMD3<Float>] = [:]
        var frameFits: [RigFitResult.FrameFit] = []
        let solveGroundPlane = groundPlaneForSolve(controller: groundPlane)

        for frame in normalized.frames {
            let targets = targetsForFrame(
                normalizedFrame: frame,
                smoothedFrame: smoothed?.frames.first(where: { $0.frameIndex == frame.frameIndex }),
                useSmoothed: settings.useSmoothedTargets
            )

            let fit = fitFrame(
                frame: frame,
                targets: targets,
                rigProfile: rigProfile,
                previousPositions: previousFramePositions,
                settings: settings,
                groundPlane: solveGroundPlane
            )

            previousFramePositions = fit.positions
            frameFits.append(
                RigFitResult.FrameFit(
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds,
                    jointPositions3D: fit.positions.mapValues {
                        SIMD3Codable(x: Double($0.x), y: Double($0.y), z: Double($0.z))
                    },
                    localRotationsEulerXYZ: fit.rotations.mapValues {
                        let euler = RotationEulerConverter.eulerXYZ(from: $0)
                        return SIMD3Codable(
                            x: Double(euler.x),
                            y: Double(euler.y),
                            z: Double(euler.z)
                        )
                    },
                    fitErrors: fit.errors,
                    fitScore: fit.score,
                    ignoredTargets: fit.ignoredTargets,
                    groundPlaneApplied: fit.groundPlaneApplied,
                    groundContactJoints: fit.groundContactJoints
                )
            )
        }

        return RigFitResult(
            schema: "com.gravitas.rotomotion.rig_fit.v0",
            sourceCaptureKind: settings.useSmoothedTargets ? "smoothed_meshy24" : "normalized_meshy24",
            rigID: rigProfile.rigID,
            rigVersion: rigProfile.rigVersion,
            frames: frameFits
        )
    }

    private static func targetsForFrame(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        smoothedFrame: SmoothedMeshyPoseCapture.Frame?,
        useSmoothed: Bool
    ) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]

        for jointName in activeJoints(for: .fullBody) {
            if useSmoothed,
               let smoothedJoint = smoothedFrame?.joints[jointName],
               !smoothedJoint.missing,
               smoothedJoint.confidence >= minimumTargetConfidence {
                result[jointName] = CGPoint(
                    x: smoothedJoint.smoothedX,
                    y: smoothedJoint.smoothedY
                )
            } else if let joint = normalizedFrame.joints[jointName],
                      !joint.missing,
                      joint.confidence >= minimumTargetConfidence {
                result[jointName] = CGPoint(x: joint.x, y: joint.y)
            }
        }

        return result
    }

    private struct FrameFitInternal {
        let positions: [String: SIMD3<Float>]
        let rotations: [String: simd_quatf]
        let errors: [String: Double]
        let score: Double
        let ignoredTargets: [String]
        let groundPlaneApplied: Bool
        let groundContactJoints: [String]
    }

    private static func fitFrame(
        frame: NormalizedMeshyPoseCapture.Frame,
        targets: [String: CGPoint],
        rigProfile: RigProfile,
        previousPositions: [String: SIMD3<Float>],
        settings: RigFitSettings,
        groundPlane: GroundPlane?
    ) -> FrameFitInternal {
        var positions: [String: SIMD3<Float>] = [:]
        var rotations: [String: simd_quatf] = [:]
        var errors: [String: Double] = [:]
        var ignored: [String] = []
        let active = Set(activeJoints(for: settings.fitMode))
        let rigJoints = rigProfile.jointByName

        guard rigJoints["Hips"] != nil else {
            return FrameFitInternal(
                positions: [:],
                rotations: [:],
                errors: [:],
                score: 0,
                ignoredTargets: CanonicalRig.jointNames,
                groundPlaneApplied: false,
                groundContactJoints: []
            )
        }

        let hipsTarget = targets["Hips"] ?? CGPoint(x: 0.5, y: 0.5)
        positions["Hips"] = SIMD3<Float>(
            Float(hipsTarget.x - 0.5),
            0,
            Float(hipsTarget.y - 0.5)
        )
        rotations["Hips"] = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

        for jointName in CanonicalRig.jointNames where jointName != "Hips" {
            guard let parentName = flattenedParent(for: jointName),
                  let parentPosition = positions[parentName],
                  let rigJoint = rigJoints[jointName] else {
                ignored.append(jointName)
                continue
            }

            let length = max(Float(rigJoint.boneLengthToParent), 0.0001)
            let target2D = active.contains(jointName) ? targets[jointName] : nil
            let desiredDirection = solvedDirection(
                jointName: jointName,
                parentPosition: parentPosition,
                target2D: target2D,
                targetWeight: settings.targetWeight
            )

            let solvedPosition = parentPosition + desiredDirection * length

            if let previous = previousPositions[jointName],
               simd_length_squared(previous - parentPosition) > 0.000001 {
                let blended = simd_mix(
                    solvedPosition,
                    previous,
                    SIMD3<Float>(repeating: Float(max(0, min(settings.previousFrameWeight, 0.95))))
                )
                let dir = safeNormalize(blended - parentPosition, fallback: desiredDirection)
                positions[jointName] = parentPosition + dir * length
            } else {
                positions[jointName] = solvedPosition
            }

            rotations[jointName] = rotationFromParentToChild(
                parent: parentPosition,
                child: positions[jointName] ?? solvedPosition
            )

            if let target2D,
               let solved = positions[jointName] {
                let solved2D = CGPoint(
                    x: CGFloat(Double(solved.x) + 0.5),
                    y: CGFloat(Double(solved.z) + 0.5)
                )
                let dx = Double(solved2D.x - target2D.x)
                let dy = Double(solved2D.y - target2D.y)
                errors[jointName] = sqrt(dx * dx + dy * dy)
            } else if active.contains(jointName) {
                ignored.append(jointName)
            }
        }

        let didApplyGround = settings.useGroundConstraint && groundPlane != nil

        if settings.useGroundConstraint,
           let groundPlane {
            applyGroundConstraint(
                positions: &positions,
                groundPlane: groundPlane,
                rigProfile: rigProfile,
                toleranceMeters: Float(settings.footContactToleranceMeters)
            )
            rotations = rotationsForPositions(positions)
            errors = fitErrors(
                positions: positions,
                targets: targets,
                activeJoints: active
            )
        }

        let score: Double
        if errors.isEmpty {
            score = 0
        } else {
            let avg = errors.values.reduce(0, +) / Double(errors.count)
            score = max(0, min(1, 1.0 - avg))
        }

        return FrameFitInternal(
            positions: positions,
            rotations: rotations,
            errors: errors,
            score: score,
            ignoredTargets: Array(Set(ignored)).sorted(),
            groundPlaneApplied: didApplyGround,
            groundContactJoints: didApplyGround ? groundContactJoints : []
        )
    }

    private struct GroundPlane {
        let point: SIMD3<Float>
        let normal: SIMD3<Float>

        func projectPointAbovePlane(
            _ pointToProject: SIMD3<Float>,
            toleranceMeters: Float
        ) -> SIMD3<Float> {
            let signedDistance = distance(pointToProject)

            if signedDistance >= -toleranceMeters {
                return pointToProject
            }

            return pointToProject - normal * signedDistance
        }

        func distance(_ p: SIMD3<Float>) -> Float {
            simd_dot(p - point, normal)
        }
    }

    private static func groundPlaneForSolve(
        controller: GroundPlaneController?
    ) -> GroundPlane? {
        guard let controller, controller.constraintEnabled else { return nil }

        let pitch = Float(controller.tumbleXRadians)
        let roll = Float(controller.rollZRadians)
        var normal = SIMD3<Float>(0, 1, 0)
        normal = rotateAroundX(normal, radians: pitch)
        normal = rotateAroundZ(normal, radians: roll)

        return GroundPlane(
            point: SIMD3<Float>(
                0,
                Float(controller.groundHeight),
                0
            ),
            normal: safeNormalize(normal, fallback: SIMD3<Float>(0, 1, 0))
        )
    }

    private static func rotateAroundX(
        _ value: SIMD3<Float>,
        radians: Float
    ) -> SIMD3<Float> {
        let c = cos(radians)
        let s = sin(radians)

        return SIMD3<Float>(
            value.x,
            value.y * c - value.z * s,
            value.y * s + value.z * c
        )
    }

    private static func rotateAroundZ(
        _ value: SIMD3<Float>,
        radians: Float
    ) -> SIMD3<Float> {
        let c = cos(radians)
        let s = sin(radians)

        return SIMD3<Float>(
            value.x * c - value.y * s,
            value.x * s + value.y * c,
            value.z
        )
    }

    private static func applyGroundConstraint(
        positions: inout [String: SIMD3<Float>],
        groundPlane: GroundPlane,
        rigProfile: RigProfile,
        toleranceMeters: Float
    ) {
        for jointName in groundContactJoints {
            guard let position = positions[jointName] else { continue }
            positions[jointName] = groundPlane.projectPointAbovePlane(
                position,
                toleranceMeters: toleranceMeters
            )
        }

        reprojectLimbLength(
            positions: &positions,
            parent: "LeftLeg",
            child: "LeftFoot",
            rigProfile: rigProfile
        )
        reprojectLimbLength(
            positions: &positions,
            parent: "LeftFoot",
            child: "LeftToeBase",
            rigProfile: rigProfile
        )
        reprojectLimbLength(
            positions: &positions,
            parent: "RightLeg",
            child: "RightFoot",
            rigProfile: rigProfile
        )
        reprojectLimbLength(
            positions: &positions,
            parent: "RightFoot",
            child: "RightToeBase",
            rigProfile: rigProfile
        )

        for jointName in groundContactJoints {
            guard let position = positions[jointName] else { continue }
            positions[jointName] = groundPlane.projectPointAbovePlane(
                position,
                toleranceMeters: 0
            )
        }
    }

    private static func reprojectLimbLength(
        positions: inout [String: SIMD3<Float>],
        parent: String,
        child: String,
        rigProfile: RigProfile
    ) {
        guard let parentPosition = positions[parent],
              let childPosition = positions[child],
              let rigJoint = rigProfile.jointByName[child] else {
            return
        }

        let length = max(Float(rigJoint.boneLengthToParent), 0.0001)
        let direction = childPosition - parentPosition

        guard simd_length_squared(direction) > 0.000001 else { return }

        positions[child] = parentPosition + simd_normalize(direction) * length
    }

    private static func rotationsForPositions(
        _ positions: [String: SIMD3<Float>]
    ) -> [String: simd_quatf] {
        var rotations: [String: simd_quatf] = [
            "Hips": simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        ]

        for jointName in CanonicalRig.jointNames where jointName != "Hips" {
            guard let parentName = flattenedParent(for: jointName),
                  let parentPosition = positions[parentName],
                  let childPosition = positions[jointName] else {
                continue
            }

            rotations[jointName] = rotationFromParentToChild(
                parent: parentPosition,
                child: childPosition
            )
        }

        return rotations
    }

    private static func fitErrors(
        positions: [String: SIMD3<Float>],
        targets: [String: CGPoint],
        activeJoints: Set<String>
    ) -> [String: Double] {
        var errors: [String: Double] = [:]

        for jointName in activeJoints {
            guard let target2D = targets[jointName],
                  let solved = positions[jointName] else {
                continue
            }

            let solved2D = CGPoint(
                x: CGFloat(Double(solved.x) + 0.5),
                y: CGFloat(Double(solved.z) + 0.5)
            )
            let dx = Double(solved2D.x - target2D.x)
            let dy = Double(solved2D.y - target2D.y)
            errors[jointName] = sqrt(dx * dx + dy * dy)
        }

        return errors
    }

    private static func solvedDirection(
        jointName: String,
        parentPosition: SIMD3<Float>,
        target2D: CGPoint?,
        targetWeight: Double
    ) -> SIMD3<Float> {
        let fallback = defaultDirection(for: jointName)

        guard let target2D else {
            return fallback
        }

        let target3D = SIMD3<Float>(
            Float(target2D.x - 0.5),
            0,
            Float(target2D.y - 0.5)
        )
        let raw = target3D - parentPosition
        guard simd_length_squared(raw) > 0.000001 else {
            return fallback
        }

        let targetDirection = simd_normalize(raw)
        let blend = Float(max(0, min(targetWeight, 1)))
        return safeNormalize(
            simd_mix(fallback, targetDirection, SIMD3<Float>(repeating: blend)),
            fallback: targetDirection
        )
    }

    private static func activeJoints(for mode: RigFitMode) -> [String] {
        switch mode {
        case .fullBody:
            return CanonicalRig.jointNames
        case .upperBody:
            return CanonicalRig.jointNames.filter {
                !$0.contains("Leg") && !$0.contains("Foot") && !$0.contains("Toe")
            }
        case .headNeck:
            return ["neck", "Head", "head_end", "headfront"]
        case .armsOnly:
            return CanonicalRig.jointNames.filter { $0.contains("Arm") || $0.contains("Hand") || $0.contains("Shoulder") }
        case .legsOnly:
            return CanonicalRig.jointNames.filter { $0.contains("Leg") || $0.contains("Foot") || $0.contains("Toe") }
        }
    }

    private static func flattenedParent(for jointName: String) -> String? {
        if let wrapped = CanonicalRig.parentByJoint[jointName] {
            return wrapped
        }

        return nil
    }

    private static func defaultDirection(for jointName: String) -> SIMD3<Float> {
        if jointName.hasPrefix("Left") {
            return SIMD3<Float>(-1, 0, 0)
        }

        if jointName.hasPrefix("Right") {
            return SIMD3<Float>(1, 0, 0)
        }

        if jointName == "Head" || jointName == "neck" || jointName.contains("Spine") {
            return SIMD3<Float>(0, 0, 1)
        }

        return SIMD3<Float>(0, 0, -1)
    }

    private static func rotationFromParentToChild(
        parent: SIMD3<Float>,
        child: SIMD3<Float>
    ) -> simd_quatf {
        let defaultAxis = SIMD3<Float>(0, 0, 1)
        let direction = safeNormalize(child - parent, fallback: defaultAxis)
        let dot = max(-1, min(1, simd_dot(defaultAxis, direction)))

        if dot > 0.999 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        if dot < -0.999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        }

        let axis = safeNormalize(simd_cross(defaultAxis, direction), fallback: SIMD3<Float>(0, 1, 0))
        let angle = acos(dot)
        return simd_quatf(angle: angle, axis: axis)
    }

    private static func safeNormalize(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        if simd_length_squared(value) > 0.000001 {
            return simd_normalize(value)
        }

        return fallback
    }
}
