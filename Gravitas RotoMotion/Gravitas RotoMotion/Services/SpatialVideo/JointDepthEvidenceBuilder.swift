import Foundation
import simd

enum JointDisparityCandidateSampler {
    static func sampleCandidates(
        jointName: String,
        normalizedLeftFrame: NormalizedMeshyPoseCapture.Frame,
        normalizedRightFrame: NormalizedMeshyPoseCapture.Frame?,
        stereoFrame: StereoMeshyJointCapture.Frame?,
        conditionedFrame: ConditionedStereoJointCapture.Frame?,
        fusedFrame: FusedStereoJointTargetCapture.Frame?,
        disparityFrame: SpatialDisparityMapCapture.Frame,
        metadata: SpatialVideoCameraMetadata,
        settings: StereoDisparitySettings
    ) -> [DisparityDepthCandidate] {
        var candidates: [(DisparityDepthCandidateSource, Double, Double)] = []

        if let left = normalizedLeftFrame.joints[jointName],
           !left.missing {
            candidates.append((.leftEyeVision, left.x, left.y))
        }

        if let right = normalizedRightFrame?.joints[jointName],
           !right.missing {
            candidates.append((.rightEyeVisionOnLeftPlate, right.x, right.y))
        }

        if let left = normalizedLeftFrame.joints[jointName],
           let right = normalizedRightFrame?.joints[jointName],
           !left.missing,
           !right.missing {
            candidates.append((
                .leftRightLerp,
                (left.x + right.x) * 0.5,
                (left.y + right.y) * 0.5
            ))
        }

        if let stereo = stereoFrame?.joints[jointName],
           stereo.validStereo,
           stereo.positionCameraXYZ.count == 3,
           let projected = projectCameraPointToLeftNormalized(
            stereo.positionCameraXYZ,
            metadata: metadata
           ) {
            candidates.append((.stereoReprojectedLeft, projected.x, projected.y))
        }

        if let conditioned = conditionedFrame?.joints[jointName],
           conditioned.positionCameraXYZ.count == 3,
           let projected = projectCameraPointToLeftNormalized(
            conditioned.positionCameraXYZ,
            metadata: metadata
           ) {
            candidates.append((.conditionedReprojectedLeft, projected.x, projected.y))
        }

        if let fused = fusedFrame?.joints[jointName],
           !fused.rejected,
           let point = fused.positionCameraXYZ,
           point.count == 3,
           let projected = projectCameraPointToLeftNormalized(
            point,
            metadata: metadata
           ) {
            candidates.append((.fusedReprojectedLeft, projected.x, projected.y))
        }

        return candidates.map { source, x, y in
            let sample = sampleDisparityDepth(
                x: x,
                y: y,
                frame: disparityFrame,
                radius: settings.jointSampleRadius
            )

            return DisparityDepthCandidate(
                source: source,
                x: x,
                y: y,
                depthMeters: sample.depthMeters,
                confidence: sample.confidence,
                status: sample.status
            )
        }
    }

    private struct DepthSample {
        let depthMeters: Double?
        let confidence: Double
        let status: String
    }

    private static func sampleDisparityDepth(
        x normalizedX: Double,
        y normalizedY: Double,
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

        let x = Int((normalizedX * Double(frame.width)).rounded())
        let y = Int(((1.0 - normalizedY) * Double(frame.height)).rounded())
        let sampleRadius = max(0, radius)

        guard x >= 0,
              x < frame.width,
              y >= 0,
              y < frame.height else {
            return DepthSample(
                depthMeters: nil,
                confidence: 0,
                status: "candidate_outside_disparity_map"
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
                   depth > 0,
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

        let nearest = values[0]
        let averageConfidence = confidences.reduce(0, +) / Float(confidences.count)

        return DepthSample(
            depthMeters: Double(nearest),
            confidence: Double(averageConfidence),
            status: "nearest_valid_depth"
        )
    }

    private static func projectCameraPointToLeftNormalized(
        _ point: [Double],
        metadata: SpatialVideoCameraMetadata
    ) -> SIMD2<Double>? {
        guard point.count == 3,
              let hFOV = metadata.horizontalFOVDegrees,
              let baseline = metadata.baselineMeters,
              metadata.imageWidth > 0,
              metadata.imageHeight > 0 else {
            return nil
        }

        let p = SIMD3<Double>(
            point[0],
            point[1],
            point[2]
        )
        let width = Double(metadata.imageWidth)
        let height = Double(metadata.imageHeight)
        let focal = 0.5 * width / tan((hFOV * .pi / 180.0) * 0.5)
        let z = max(-p.z, 0.000001)
        let leftEyeX = -baseline * 0.5
        let px = ((p.x - leftEyeX) * focal / z) + width * 0.5
        let py = height * 0.5 - (p.y * focal / z)

        return SIMD2<Double>(
            px / width,
            1.0 - (py / height)
        )
    }
}

enum DisparityCandidateSelector {
    static func selectWinner(
        candidates: [DisparityDepthCandidate]
    ) -> DisparityDepthCandidate? {
        let valid = candidates.filter { candidate in
            guard let depth = candidate.depthMeters,
                  depth.isFinite,
                  depth > 0,
                  candidate.confidence > 0 else {
                return false
            }

            return true
        }

        return valid.min {
            if $0.depthMeters == $1.depthMeters {
                return $0.confidence > $1.confidence
            }

            return ($0.depthMeters ?? .greatestFiniteMagnitude)
                < ($1.depthMeters ?? .greatestFiniteMagnitude)
        }
    }
}

enum JointDepthEvidenceBuilder {
    static func build(
        stereo: StereoMeshyJointCapture,
        disparity: SpatialDisparityMapCapture,
        normalizedLeft: NormalizedMeshyPoseCapture,
        settings: StereoDisparitySettings
    ) -> JointDepthEvidenceCapture {
        buildCandidateBased(
            disparity: disparity,
            normalizedLeft: normalizedLeft,
            normalizedRight: nil,
            stereo: stereo,
            conditioned: nil,
            fused: nil,
            metadata: disparity.cameraMetadata,
            settings: settings
        )
    }

    static func buildCandidateBased(
        disparity: SpatialDisparityMapCapture,
        normalizedLeft: NormalizedMeshyPoseCapture,
        normalizedRight: NormalizedMeshyPoseCapture?,
        stereo: StereoMeshyJointCapture?,
        conditioned: ConditionedStereoJointCapture?,
        fused: FusedStereoJointTargetCapture?,
        metadata: SpatialVideoCameraMetadata,
        settings: StereoDisparitySettings
    ) -> JointDepthEvidenceCapture {
        var frames: [JointDepthEvidenceCapture.Frame] = []
        frames.reserveCapacity(normalizedLeft.frames.count)

        for leftFrame in normalizedLeft.frames {
            guard let disparityFrame = nearestFrame(
                to: leftFrame.timeSeconds,
                in: disparity.frames
            ) else {
                continue
            }

            let rightFrame = normalizedRight.flatMap {
                nearestFrame(
                    to: leftFrame.timeSeconds,
                    in: $0.frames
                )
            }
            let stereoFrame = stereo.flatMap {
                nearestFrame(
                    to: leftFrame.timeSeconds,
                    in: $0.frames
                )
            }
            let conditionedFrame = conditioned.flatMap {
                nearestFrame(
                    to: leftFrame.timeSeconds,
                    in: $0.frames
                )
            }
            let fusedFrame = fused.flatMap {
                nearestFrame(
                    to: leftFrame.timeSeconds,
                    in: $0.frames
                )
            }

            var allCandidates: [String: [DisparityDepthCandidate]] = [:]

            for jointName in CanonicalRig.jointNames {
                allCandidates[jointName] = JointDisparityCandidateSampler.sampleCandidates(
                    jointName: jointName,
                    normalizedLeftFrame: leftFrame,
                    normalizedRightFrame: rightFrame,
                    stereoFrame: stereoFrame,
                    conditionedFrame: conditionedFrame,
                    fusedFrame: fusedFrame,
                    disparityFrame: disparityFrame,
                    metadata: metadata,
                    settings: settings
                )
            }

            var joints: [String: JointDepthEvidenceCapture.JointEvidence] = [:]

            for jointName in CanonicalRig.jointNames {
                let candidates = allCandidates[jointName] ?? []
                let winner = DisparityCandidateSelector.selectWinner(
                    candidates: candidates
                )
                let stereoJoint = stereoFrame?.joints[jointName]
                let stereoDepth = stereoJoint?.validStereo == true
                    ? stereoJoint?.depthMeters
                    : nil
                let depthDelta = stereoDepth.flatMap { stereoDepth in
                    winner?.depthMeters.map { $0 - stereoDepth }
                }

                joints[jointName] = JointDepthEvidenceCapture.JointEvidence(
                    jointName: jointName,
                    stereoJointDepthMeters: stereoDepth,
                    stereoJointConfidence: stereoJoint?.stereoConfidence ?? 0,
                    disparityDepthMeters: winner?.depthMeters,
                    disparityConfidence: winner?.confidence ?? 0,
                    winningCandidateSource: winner?.source.rawValue,
                    candidates: candidates,
                    depthDeltaMeters: depthDelta,
                    passesDepthValidation: winner != nil,
                    depthDirectionStatus: "not_evaluated",
                    status: winner.map { "winner_\($0.source.rawValue)" }
                        ?? "no_valid_disparity_candidate"
                )
            }

            frames.append(
                JointDepthEvidenceCapture.Frame(
                    frameIndex: leftFrame.frameIndex,
                    timeSeconds: leftFrame.timeSeconds,
                    joints: joints
                )
            )
        }

        return JointDepthEvidenceCapture(
            schema: JointDepthEvidenceCapture.currentSchema,
            frames: frames
        )
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [SpatialDisparityMapCapture.Frame]
    ) -> SpatialDisparityMapCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
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
        in frames: [StereoMeshyJointCapture.Frame]
    ) -> StereoMeshyJointCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [ConditionedStereoJointCapture.Frame]
    ) -> ConditionedStereoJointCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func nearestFrame(
        to timeSeconds: Double,
        in frames: [FusedStereoJointTargetCapture.Frame]
    ) -> FusedStereoJointTargetCapture.Frame? {
        frames.min {
            abs($0.timeSeconds - timeSeconds) < abs($1.timeSeconds - timeSeconds)
        }
    }

    private static func bodyDepthBand(
        from candidateEvidence: [String: [DisparityDepthCandidate]]
    ) -> ClosedRange<Double>? {
        let bodyJoints = [
            "Hips",
            "Spine",
            "Spine01",
            "Spine02",
            "neck",
            "Head",
            "LeftShoulder",
            "RightShoulder",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var depths: [Double] = []

        for joint in bodyJoints {
            for candidate in candidateEvidence[joint] ?? [] {
                if let depth = candidate.depthMeters,
                   depth.isFinite,
                   depth > 0,
                   candidate.confidence > 0 {
                    depths.append(depth)
                }
            }
        }

        guard !depths.isEmpty else {
            return nil
        }

        depths.sort()
        let median = depths[depths.count / 2]

        return max(0.2, median - 1.25)...(median + 1.25)
    }
}
