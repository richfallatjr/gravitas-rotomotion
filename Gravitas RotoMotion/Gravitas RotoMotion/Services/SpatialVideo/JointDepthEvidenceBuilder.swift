import Foundation

enum JointDepthEvidenceBuilder {
    static func build(
        stereo: StereoMeshyJointCapture,
        disparity: SpatialDisparityMapCapture,
        normalizedLeft: NormalizedMeshyPoseCapture,
        settings: StereoDisparitySettings
    ) -> JointDepthEvidenceCapture {
        var frames: [JointDepthEvidenceCapture.Frame] = []
        frames.reserveCapacity(stereo.frames.count)

        for stereoFrame in stereo.frames {
            guard let dispFrame = nearestDisparityFrame(
                to: stereoFrame.timeSeconds,
                in: disparity.frames
            ),
            let leftFrame = nearestNormalizedFrame(
                to: stereoFrame.timeSeconds,
                in: normalizedLeft.frames
            ) else {
                continue
            }

            var joints: [String: JointDepthEvidenceCapture.JointEvidence] = [:]

            for jointName in CanonicalRig.jointNames {
                guard let leftJoint = leftFrame.joints[jointName],
                      !leftJoint.missing else {
                    continue
                }

                let stereoJoint = stereoFrame.joints[jointName]
                let sample = sampleDepthAroundJoint(
                    jointX: leftJoint.x,
                    jointY: leftJoint.y,
                    frame: dispFrame,
                    radius: settings.jointSampleRadius
                )
                let stereoDepth = stereoJoint?.validStereo == true
                    ? stereoJoint?.depthMeters
                    : nil

                let delta = stereoDepth.flatMap { stereoDepth in
                    sample.depthMeters.map { $0 - stereoDepth }
                }
                let passes = delta.map { abs($0) <= settings.maxJointDepthDeltaMeters } ?? false

                joints[jointName] = JointDepthEvidenceCapture.JointEvidence(
                    jointName: jointName,
                    stereoJointDepthMeters: stereoDepth,
                    stereoJointConfidence: stereoJoint?.stereoConfidence ?? 0,
                    disparityDepthMeters: sample.depthMeters,
                    disparityConfidence: sample.confidence,
                    depthDeltaMeters: delta,
                    passesDepthValidation: passes,
                    depthDirectionStatus: "not_evaluated",
                    status: sample.status
                )
            }

            applyDepthDirectionChecks(
                to: &joints,
                settings: settings
            )

            frames.append(
                JointDepthEvidenceCapture.Frame(
                    frameIndex: stereoFrame.frameIndex,
                    timeSeconds: stereoFrame.timeSeconds,
                    joints: joints
                )
            )
        }

        return JointDepthEvidenceCapture(
            schema: JointDepthEvidenceCapture.currentSchema,
            frames: frames
        )
    }

    private struct DepthSample {
        let depthMeters: Double?
        let confidence: Double
        let status: String
    }

    private static func nearestDisparityFrame(
        to timeSeconds: Double,
        in frames: [SpatialDisparityMapCapture.Frame]
    ) -> SpatialDisparityMapCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func nearestNormalizedFrame(
        to timeSeconds: Double,
        in frames: [NormalizedMeshyPoseCapture.Frame]
    ) -> NormalizedMeshyPoseCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func sampleDepthAroundJoint(
        jointX: Double,
        jointY: Double,
        frame: SpatialDisparityMapCapture.Frame,
        radius: Int
    ) -> DepthSample {
        guard frame.width > 0,
              frame.height > 0,
              frame.depthMeters.count == frame.width * frame.height,
              frame.confidence.count == frame.width * frame.height else {
            return DepthSample(
                depthMeters: nil,
                confidence: 0,
                status: "invalid_disparity_frame"
            )
        }

        let x = Int((jointX * Double(frame.width)).rounded())
        let y = Int(((1.0 - jointY) * Double(frame.height)).rounded())
        let sampleRadius = max(0, radius)

        guard x >= 0,
              x < frame.width,
              y >= 0,
              y < frame.height else {
            return DepthSample(
                depthMeters: nil,
                confidence: 0,
                status: "joint_outside_disparity_map"
            )
        }

        var values: [Float] = []
        var confidences: [Float] = []

        for yy in max(0, y - sampleRadius)...min(frame.height - 1, y + sampleRadius) {
            for xx in max(0, x - sampleRadius)...min(frame.width - 1, x + sampleRadius) {
                let index = yy * frame.width + xx
                let depth = frame.depthMeters[index]
                let confidence = frame.confidence[index]

                if depth.isFinite,
                   confidence > 0 {
                    values.append(depth)
                    confidences.append(confidence)
                }
            }
        }

        guard !values.isEmpty else {
            return DepthSample(
                depthMeters: nil,
                confidence: 0,
                status: "no_valid_disparity_samples"
            )
        }

        values.sort()

        let median = values[values.count / 2]
        let averageConfidence = confidences.reduce(0, +) / Float(confidences.count)

        return DepthSample(
            depthMeters: Double(median),
            confidence: Double(averageConfidence),
            status: "sampled_median"
        )
    }

    private static func applyDepthDirectionChecks(
        to joints: inout [String: JointDepthEvidenceCapture.JointEvidence],
        settings: StereoDisparitySettings
    ) {
        for (parentName, childName) in CanonicalRig.bonePairs {
            guard let parent = joints[parentName],
                  var child = joints[childName],
                  let parentStereoDepth = parent.stereoJointDepthMeters,
                  let childStereoDepth = child.stereoJointDepthMeters,
                  let parentDisparityDepth = parent.disparityDepthMeters,
                  let childDisparityDepth = child.disparityDepthMeters else {
                continue
            }

            let stereoDelta = childStereoDepth - parentStereoDepth
            let disparityDelta = childDisparityDepth - parentDisparityDepth

            guard abs(stereoDelta) > settings.minDepthDirectionDeltaMeters,
                  abs(disparityDelta) > settings.minDepthDirectionDeltaMeters,
                  (stereoDelta > 0) != (disparityDelta > 0) else {
                continue
            }

            child = JointDepthEvidenceCapture.JointEvidence(
                jointName: child.jointName,
                stereoJointDepthMeters: child.stereoJointDepthMeters,
                stereoJointConfidence: child.stereoJointConfidence,
                disparityDepthMeters: child.disparityDepthMeters,
                disparityConfidence: child.disparityConfidence,
                depthDeltaMeters: child.depthDeltaMeters,
                passesDepthValidation: false,
                depthDirectionStatus: "direction_mismatch_parent_\(parentName)",
                status: child.status
            )

            joints[childName] = child
        }
    }
}
