import Foundation
import simd

struct RigConstraintValidation {
    let passesBoneReach: Bool
    let nearestReachablePosition: SIMD3<Double>?
    let reason: String
}

enum StereoJointTargetFuser {
    static func fuse(
        left: NormalizedMeshyPoseCapture,
        right: NormalizedMeshyPoseCapture,
        stereo: StereoMeshyJointCapture?,
        depthEvidence: JointDepthEvidenceCapture?,
        metadata: SpatialVideoCameraMetadata,
        yConvention: NormalizedImageYConvention,
        settings: StereoTargetFusionSettings,
        rigProfile: USDZSkeletonProfile?
    ) -> FusedStereoJointTargetCapture {
        var previousPositions: [String: SIMD3<Double>] = [:]
        var holdCounts: [String: Int] = [:]
        var fusedFrames: [FusedStereoJointTargetCapture.Frame] = []
        let sourceFrames = fusionSourceFrames(
            left: left,
            stereo: stereo
        )

        fusedFrames.reserveCapacity(sourceFrames.count)

        for sourceFrame in sourceFrames {
            guard let leftFrame = nearestFrame(
                to: sourceFrame.timeSeconds,
                in: left.frames
            ),
            let rightFrame = nearestFrame(
                to: sourceFrame.timeSeconds,
                in: right.frames
            ) else {
                continue
            }

            let stereoFrame = sourceFrame.stereoFrame ?? nearestFrame(
                to: sourceFrame.timeSeconds,
                in: stereo?.frames ?? []
            )
            let evidenceFrame = nearestFrame(
                to: sourceFrame.timeSeconds,
                in: depthEvidence?.frames ?? []
            )
            var joints: [String: FusedStereoJointTargetCapture.JointTarget] = [:]

            for jointName in CanonicalRig.jointNames {
                let target = fuseJoint(
                    jointName: jointName,
                    leftJoint: leftFrame.joints[jointName],
                    rightJoint: rightFrame.joints[jointName],
                    stereoJoint: stereoFrame?.joints[jointName],
                    evidence: evidenceFrame?.joints[jointName],
                    metadata: metadata,
                    yConvention: yConvention,
                    settings: settings,
                    rigProfile: rigProfile,
                    currentFrameTargets: joints,
                    previousPosition: previousPositions[jointName],
                    holdCount: holdCounts[jointName] ?? 0
                )

                joints[jointName] = target

                if let position = vector(from: target.positionCameraXYZ),
                   !target.rejected {
                    previousPositions[jointName] = position
                    holdCounts[jointName] = target.status.contains("held")
                        ? (holdCounts[jointName] ?? 0) + 1
                        : 0
                }
            }

            fusedFrames.append(
                FusedStereoJointTargetCapture.Frame(
                    frameIndex: sourceFrame.frameIndex,
                    timeSeconds: sourceFrame.timeSeconds,
                    joints: joints
                )
            )
        }

        return FusedStereoJointTargetCapture(
            schema: FusedStereoJointTargetCapture.currentSchema,
            frames: fusedFrames
        )
    }

    private struct FusionSourceFrame {
        let frameIndex: Int
        let timeSeconds: Double
        let stereoFrame: StereoMeshyJointCapture.Frame?
    }

    private static func fusionSourceFrames(
        left: NormalizedMeshyPoseCapture,
        stereo: StereoMeshyJointCapture?
    ) -> [FusionSourceFrame] {
        if let stereo,
           !stereo.frames.isEmpty {
            return stereo.frames.map {
                FusionSourceFrame(
                    frameIndex: $0.frameIndex,
                    timeSeconds: $0.timeSeconds,
                    stereoFrame: $0
                )
            }
        }

        return left.frames.map {
            FusionSourceFrame(
                frameIndex: $0.frameIndex,
                timeSeconds: $0.timeSeconds,
                stereoFrame: nil
            )
        }
    }

    private static func fuseJoint(
        jointName: String,
        leftJoint: NormalizedMeshyPoseCapture.Joint?,
        rightJoint: NormalizedMeshyPoseCapture.Joint?,
        stereoJoint: StereoMeshyJointCapture.Joint?,
        evidence: JointDepthEvidenceCapture.JointEvidence?,
        metadata: SpatialVideoCameraMetadata,
        yConvention: NormalizedImageYConvention,
        settings: StereoTargetFusionSettings,
        rigProfile: USDZSkeletonProfile?,
        currentFrameTargets: [String: FusedStereoJointTargetCapture.JointTarget],
        previousPosition: SIMD3<Double>?,
        holdCount: Int
    ) -> FusedStereoJointTargetCapture.JointTarget {
        guard let leftJoint,
              let rightJoint,
              let envelope = StereoVisionEnvelopeBuilder.buildEnvelope(
                jointName: jointName,
                leftJoint: leftJoint,
                rightJoint: rightJoint,
                metadata: metadata,
                yConvention: yConvention
              ) else {
            return heldOrRejectedTarget(
                jointName: jointName,
                leftJoint: leftJoint,
                rightJoint: rightJoint,
                previousPosition: previousPosition,
                holdCount: holdCount,
                maxHoldFrames: settings.maxHoldFrames,
                status: "missing_stereo_vision_envelope"
            )
        }

        let visionPoint = visionStereoPoint(
            stereoJoint: stereoJoint,
            fallback: envelope.closestPointCameraXYZ
        )
        let visionDepth = stereoJoint?.validStereo == true
            ? stereoJoint?.depthMeters
            : max(-visionPoint.z, 0.000001)
        let disparityDepth = evidence?.disparityDepthMeters
        let depthDelta = visionDepth.flatMap { visionDepth in
            disparityDepth.map { $0 - visionDepth }
        }
        let disparityValid = disparityDepth != nil && (evidence?.disparityConfidence ?? 0) > 0
        let depthDisagrees = depthDelta.map {
            abs($0) > settings.maxVisionDisparityDepthDeltaMeters
        } ?? true

        var targetPoint = visionPoint
        var confidence = envelope.confidence
        var statuses: [String] = []

        if envelope.stereoEnvelopeWidthPixels > settings.maxStereoEnvelopeWidthPixels {
            confidence *= 0.5
            statuses.append("wide_stereo_envelope")
        }

        if envelope.raySeparationMeters > settings.maxRaySeparationMeters {
            confidence *= 0.5
            statuses.append("large_ray_separation")
        }

        if let disparityDepth,
           disparityValid {
            if depthDisagrees {
                targetPoint = pointAlongLeftRayAtDepth(
                    leftRayOrigin: envelope.leftRayOrigin,
                    leftRayDirection: envelope.leftRayDirection,
                    depthMeters: disparityDepth
                )
                confidence *= 0.7
                statuses.append("depth_corrected_disparity_mismatch")
            } else if let visionDepth {
                let blend = max(0, min(settings.disparityDepthBlend, 1))
                let blendedDepth = visionDepth * (1.0 - blend) + disparityDepth * blend
                targetPoint = pointAlongLeftRayAtDepth(
                    leftRayOrigin: envelope.leftRayOrigin,
                    leftRayDirection: envelope.leftRayDirection,
                    depthMeters: blendedDepth
                )
                statuses.append("depth_blended_disparity")
            }
        } else {
            confidence *= 0.75
            statuses.append("accepted_no_disparity")
        }

        let rigValidation = validateRigReach(
            jointName: jointName,
            candidate: targetPoint,
            currentFrameTargets: currentFrameTargets,
            rigProfile: rigProfile
        )

        if !rigValidation.passesBoneReach {
            confidence *= 0.5
            statuses.append(rigValidation.reason)
        }

        let temporalPop = previousPosition.map {
            simd_length(targetPoint - $0)
        }

        if let previousPosition,
           let temporalPop,
           temporalPop > settings.maxTemporalJointJumpMeters,
           depthDisagrees {
            if holdCount < settings.maxHoldFrames {
                return target(
                    jointName: jointName,
                    position: previousPosition,
                    leftJoint: leftJoint,
                    rightJoint: rightJoint,
                    visionPoint: visionPoint,
                    disparityDepth: disparityDepth,
                    confidence: max(0.05, confidence * 0.5),
                    rejected: false,
                    status: "held_temporal_pop",
                    depthDelta: depthDelta,
                    temporalPop: temporalPop,
                    envelopeWidth: envelope.stereoEnvelopeWidthPixels,
                    envelopeSeparation: envelope.raySeparationMeters
                )
            }

            return target(
                jointName: jointName,
                position: nil,
                leftJoint: leftJoint,
                rightJoint: rightJoint,
                visionPoint: visionPoint,
                disparityDepth: disparityDepth,
                confidence: 0,
                rejected: true,
                status: "rejected_temporal_pop",
                depthDelta: depthDelta,
                temporalPop: temporalPop,
                envelopeWidth: envelope.stereoEnvelopeWidthPixels,
                envelopeSeparation: envelope.raySeparationMeters
            )
        }

        if confidence < settings.minFusedConfidence {
            if let previousPosition,
               holdCount < settings.maxHoldFrames {
                return target(
                    jointName: jointName,
                    position: previousPosition,
                    leftJoint: leftJoint,
                    rightJoint: rightJoint,
                    visionPoint: visionPoint,
                    disparityDepth: disparityDepth,
                    confidence: confidence,
                    rejected: false,
                    status: "held_low_fused_confidence",
                    depthDelta: depthDelta,
                    temporalPop: temporalPop,
                    envelopeWidth: envelope.stereoEnvelopeWidthPixels,
                    envelopeSeparation: envelope.raySeparationMeters
                )
            }

            return target(
                jointName: jointName,
                position: nil,
                leftJoint: leftJoint,
                rightJoint: rightJoint,
                visionPoint: visionPoint,
                disparityDepth: disparityDepth,
                confidence: confidence,
                rejected: true,
                status: "rejected_low_fused_confidence",
                depthDelta: depthDelta,
                temporalPop: temporalPop,
                envelopeWidth: envelope.stereoEnvelopeWidthPixels,
                envelopeSeparation: envelope.raySeparationMeters
            )
        }

        if statuses.isEmpty {
            statuses.append("accepted_fused")
        }

        return target(
            jointName: jointName,
            position: targetPoint,
            leftJoint: leftJoint,
            rightJoint: rightJoint,
            visionPoint: visionPoint,
            disparityDepth: disparityDepth,
            confidence: confidence,
            rejected: false,
            status: statuses.joined(separator: "|"),
            depthDelta: depthDelta,
            temporalPop: temporalPop,
            envelopeWidth: envelope.stereoEnvelopeWidthPixels,
            envelopeSeparation: envelope.raySeparationMeters
        )
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [NormalizedMeshyPoseCapture.Frame]
    ) -> NormalizedMeshyPoseCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [JointDepthEvidenceCapture.Frame]
    ) -> JointDepthEvidenceCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [StereoMeshyJointCapture.Frame]
    ) -> StereoMeshyJointCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func visionStereoPoint(
        stereoJoint: StereoMeshyJointCapture.Joint?,
        fallback: SIMD3<Double>
    ) -> SIMD3<Double> {
        guard let stereoJoint,
              stereoJoint.validStereo,
              stereoJoint.positionCameraXYZ.count == 3 else {
            return fallback
        }

        return SIMD3<Double>(
            stereoJoint.positionCameraXYZ[0],
            stereoJoint.positionCameraXYZ[1],
            stereoJoint.positionCameraXYZ[2]
        )
    }

    private static func pointAlongLeftRayAtDepth(
        leftRayOrigin: SIMD3<Double>,
        leftRayDirection: SIMD3<Double>,
        depthMeters: Double
    ) -> SIMD3<Double> {
        let denominator = min(leftRayDirection.z, -0.000001)
        let t = (-depthMeters - leftRayOrigin.z) / denominator

        return leftRayOrigin + leftRayDirection * max(0, t)
    }

    private static func validateRigReach(
        jointName: String,
        candidate: SIMD3<Double>,
        currentFrameTargets: [String: FusedStereoJointTargetCapture.JointTarget],
        rigProfile: USDZSkeletonProfile?
    ) -> RigConstraintValidation {
        guard let parentName = CanonicalRig.parentByJoint[jointName] ?? nil,
              let parentTarget = currentFrameTargets[parentName],
              !parentTarget.rejected,
              let parentPosition = vector(from: parentTarget.positionCameraXYZ),
              let boneLengthMeters = measuredBoneLengthMeters(
                jointName: jointName,
                rigProfile: rigProfile
              ),
              boneLengthMeters > 0 else {
            return RigConstraintValidation(
                passesBoneReach: true,
                nearestReachablePosition: nil,
                reason: "not_evaluated"
            )
        }

        let offset = candidate - parentPosition
        let distance = simd_length(offset)
        let maxReach = boneLengthMeters * 1.35

        guard distance > maxReach else {
            return RigConstraintValidation(
                passesBoneReach: true,
                nearestReachablePosition: nil,
                reason: "passes_bone_reach"
            )
        }

        let nearest = distance > 0.000001
            ? parentPosition + offset / distance * maxReach
            : parentPosition

        return RigConstraintValidation(
            passesBoneReach: false,
            nearestReachablePosition: nearest,
            reason: "rig_reach_suspect_parent_\(parentName)"
        )
    }

    private static func measuredBoneLengthMeters(
        jointName: String,
        rigProfile: USDZSkeletonProfile?
    ) -> Double? {
        guard let rigProfile,
              let rawLength = rigProfile.boneLengths[jointName] else {
            return nil
        }

        return rawLength * max(rigProfile.unitScaleToMeters ?? 1.0, 0.000001)
    }

    private static func heldOrRejectedTarget(
        jointName: String,
        leftJoint: NormalizedMeshyPoseCapture.Joint?,
        rightJoint: NormalizedMeshyPoseCapture.Joint?,
        previousPosition: SIMD3<Double>?,
        holdCount: Int,
        maxHoldFrames: Int,
        status: String
    ) -> FusedStereoJointTargetCapture.JointTarget {
        if let previousPosition,
           holdCount < maxHoldFrames {
            return target(
                jointName: jointName,
                position: previousPosition,
                leftJoint: leftJoint,
                rightJoint: rightJoint,
                visionPoint: nil,
                disparityDepth: nil,
                confidence: 0.05,
                rejected: false,
                status: "held_\(status)",
                depthDelta: nil,
                temporalPop: nil,
                envelopeWidth: nil,
                envelopeSeparation: nil
            )
        }

        return target(
            jointName: jointName,
            position: nil,
            leftJoint: leftJoint,
            rightJoint: rightJoint,
            visionPoint: nil,
            disparityDepth: nil,
            confidence: 0,
            rejected: true,
            status: "rejected_\(status)",
            depthDelta: nil,
            temporalPop: nil,
            envelopeWidth: nil,
            envelopeSeparation: nil
        )
    }

    private static func target(
        jointName: String,
        position: SIMD3<Double>?,
        leftJoint: NormalizedMeshyPoseCapture.Joint?,
        rightJoint: NormalizedMeshyPoseCapture.Joint?,
        visionPoint: SIMD3<Double>?,
        disparityDepth: Double?,
        confidence: Double,
        rejected: Bool,
        status: String,
        depthDelta: Double?,
        temporalPop: Double?,
        envelopeWidth: Double?,
        envelopeSeparation: Double?
    ) -> FusedStereoJointTargetCapture.JointTarget {
        FusedStereoJointTargetCapture.JointTarget(
            jointName: jointName,
            positionCameraXYZ: position.map(vectorArray),
            leftX: leftJoint?.x,
            leftY: leftJoint?.y,
            rightX: rightJoint?.x,
            rightY: rightJoint?.y,
            visionStereoPositionCameraXYZ: visionPoint.map(vectorArray),
            disparityDepthMeters: disparityDepth,
            confidence: confidence,
            rejected: rejected,
            status: status,
            visionDisparityDepthDeltaMeters: depthDelta,
            temporalPopDistanceMeters: temporalPop,
            stereoEnvelopeWidthPixels: envelopeWidth,
            stereoEnvelopeSeparationMeters: envelopeSeparation
        )
    }

    private static func vectorArray(
        _ value: SIMD3<Double>
    ) -> [Double] {
        [
            value.x,
            value.y,
            value.z
        ]
    }

    private static func vector(
        from values: [Double]?
    ) -> SIMD3<Double>? {
        guard let values,
              values.count == 3 else {
            return nil
        }

        return SIMD3<Double>(
            values[0],
            values[1],
            values[2]
        )
    }
}
