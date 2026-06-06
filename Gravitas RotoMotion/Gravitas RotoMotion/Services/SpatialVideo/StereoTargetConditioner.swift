import Foundation
import simd

enum StereoTargetConditioner {
    static func condition(
        stereo: StereoMeshyJointCapture,
        settings: StereoTargetConditioningSettings = .default
    ) -> ConditionedStereoJointCapture {
        var previousByJoint: [String: SIMD3<Double>] = [:]
        var holdCountsByJoint: [String: Int] = [:]
        var conditionedFrames: [ConditionedStereoJointCapture.Frame] = []

        for frame in stereo.frames {
            var conditionedJoints: [String: ConditionedStereoJointCapture.Joint] = [:]
            let hipsRaw = rawPosition("Hips", in: frame)
            let spineRaw = rawPosition("Spine", in: frame)

            for jointName in CanonicalRig.jointNames {
                guard let rawJoint = frame.joints[jointName] else {
                    continue
                }

                let previous = previousByJoint[jointName]
                let raw = rawJoint.validStereo && rawJoint.positionCameraXYZ.count == 3
                    ? SIMD3<Double>(
                        rawJoint.positionCameraXYZ[0],
                        rawJoint.positionCameraXYZ[1],
                        rawJoint.positionCameraXYZ[2]
                    )
                    : nil

                let result = conditionJoint(
                    jointName: jointName,
                    raw: raw,
                    rawJoint: rawJoint,
                    previous: previous,
                    hipsRaw: hipsRaw,
                    spineRaw: spineRaw,
                    holdCount: holdCountsByJoint[jointName] ?? 0,
                    settings: settings
                )

                if let output = result.position {
                    previousByJoint[jointName] = output
                    holdCountsByJoint[jointName] = result.holdCount

                    let delta = raw.map { output - $0 } ?? SIMD3<Double>(0, 0, 0)

                    conditionedJoints[jointName] = ConditionedStereoJointCapture.Joint(
                        positionCameraXYZ: [
                            output.x,
                            output.y,
                            output.z
                        ],
                        confidence: result.confidence,
                        sourceValidStereo: rawJoint.validStereo,
                        conditioningDelta: [
                            delta.x,
                            delta.y,
                            delta.z
                        ],
                        status: result.status
                    )
                }
            }

            conditionedFrames.append(
                ConditionedStereoJointCapture.Frame(
                    frameIndex: frame.frameIndex,
                    timeSeconds: frame.timeSeconds,
                    joints: conditionedJoints
                )
            )
        }

        return ConditionedStereoJointCapture(
            schema: ConditionedStereoJointCapture.currentSchema,
            sourceSchema: stereo.schema,
            frames: conditionedFrames
        )
    }

    private struct ConditionResult {
        let position: SIMD3<Double>?
        let confidence: Double
        let holdCount: Int
        let status: String
    }

    private static func conditionJoint(
        jointName: String,
        raw: SIMD3<Double>?,
        rawJoint: StereoMeshyJointCapture.Joint,
        previous: SIMD3<Double>?,
        hipsRaw: SIMD3<Double>?,
        spineRaw: SIMD3<Double>?,
        holdCount: Int,
        settings: StereoTargetConditioningSettings
    ) -> ConditionResult {
        guard let raw else {
            if let previous,
               holdCount < settings.maxHoldFrames {
                return ConditionResult(
                    position: previous,
                    confidence: 0.1,
                    holdCount: holdCount + 1,
                    status: "held_missing_raw"
                )
            }

            return ConditionResult(
                position: nil,
                confidence: 0,
                holdCount: holdCount,
                status: "rejected_missing_raw"
            )
        }

        let rawConfidence = rawJoint.stereoConfidence

        guard rawConfidence >= settings.minConfidence else {
            if let previous,
               holdCount < settings.maxHoldFrames {
                return ConditionResult(
                    position: previous,
                    confidence: rawConfidence,
                    holdCount: holdCount + 1,
                    status: "held_low_confidence"
                )
            }

            return ConditionResult(
                position: raw,
                confidence: rawConfidence,
                holdCount: 0,
                status: "accepted_low_confidence_no_previous"
            )
        }

        if let previous {
            let jump = simd_length(raw - previous)

            if jump > settings.maxFrameJumpMeters,
               holdCount < settings.maxHoldFrames {
                return ConditionResult(
                    position: previous,
                    confidence: rawConfidence,
                    holdCount: holdCount + 1,
                    status: "held_motion_outlier"
                )
            }

            if let depthStatus = relativeDepthStatus(
                jointName: jointName,
                raw: raw,
                previous: previous,
                hipsRaw: hipsRaw,
                spineRaw: spineRaw,
                settings: settings
            ),
               holdCount < settings.maxHoldFrames {
                return ConditionResult(
                    position: previous,
                    confidence: rawConfidence,
                    holdCount: holdCount + 1,
                    status: depthStatus
                )
            }

            let smoothed = previous + (raw - previous) * settings.smoothingAlpha

            return ConditionResult(
                position: smoothed,
                confidence: rawConfidence,
                holdCount: 0,
                status: "smoothed"
            )
        }

        return ConditionResult(
            position: raw,
            confidence: rawConfidence,
            holdCount: 0,
            status: "accepted_first"
        )
    }

    private static func relativeDepthStatus(
        jointName: String,
        raw: SIMD3<Double>,
        previous: SIMD3<Double>,
        hipsRaw: SIMD3<Double>?,
        spineRaw: SIMD3<Double>?,
        settings: StereoTargetConditioningSettings
    ) -> String? {
        guard jointName != "Hips",
              let bodyReference = hipsRaw ?? spineRaw else {
            return nil
        }

        let rawRelativeDepth = raw.z - bodyReference.z
        let previousRelativeDepth = previous.z - bodyReference.z
        let depthJump = abs(rawRelativeDepth - previousRelativeDepth)

        guard depthJump > settings.maxRelativeDepthJumpMeters else {
            return nil
        }

        return "held_relative_depth_outlier"
    }

    private static func rawPosition(
        _ joint: String,
        in frame: StereoMeshyJointCapture.Frame
    ) -> SIMD3<Double>? {
        guard let j = frame.joints[joint],
              j.validStereo,
              j.positionCameraXYZ.count == 3 else {
            return nil
        }

        return SIMD3<Double>(
            j.positionCameraXYZ[0],
            j.positionCameraXYZ[1],
            j.positionCameraXYZ[2]
        )
    }
}
