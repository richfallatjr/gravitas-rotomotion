import Foundation

enum PoseSmoother2D {
    static func smooth(
        normalized: NormalizedMeshyPoseCapture,
        settings: SmoothedMeshyPoseCapture.SmoothingSettings
    ) -> SmoothedMeshyPoseCapture {
        let frameByIndex = Dictionary(
            uniqueKeysWithValues: normalized.frames.map { ($0.frameIndex, $0) }
        )
        let sortedFrames = normalized.frames.sorted { $0.frameIndex < $1.frameIndex }

        let outputFrames = sortedFrames.map { frame in
            var joints: [String: SmoothedMeshyPoseCapture.Joint] = [:]

            for jointName in CanonicalRig.jointNames {
                guard let rawJoint = frame.joints[jointName] else {
                    continue
                }

                let jointEnabled = settings.perJointEnabled[jointName] ?? true
                let enabled = settings.globalEnabled && jointEnabled
                let smoothed = enabled
                    ? weightedAverage(
                        jointName: jointName,
                        centerFrameIndex: frame.frameIndex,
                        frameByIndex: frameByIndex,
                        settings: settings
                    )
                    : (x: rawJoint.x, y: rawJoint.y)

                joints[jointName] = SmoothedMeshyPoseCapture.Joint(
                    rawX: rawJoint.x,
                    rawY: rawJoint.y,
                    smoothedX: smoothed.x,
                    smoothedY: smoothed.y,
                    deltaX: smoothed.x - rawJoint.x,
                    deltaY: smoothed.y - rawJoint.y,
                    confidence: rawJoint.confidence,
                    smoothingEnabled: enabled,
                    missing: rawJoint.missing,
                    generated: rawJoint.generated
                )
            }

            return SmoothedMeshyPoseCapture.Frame(
                frameIndex: frame.frameIndex,
                timeSeconds: frame.timeSeconds,
                timecode: frame.timecode,
                joints: joints
            )
        }

        return SmoothedMeshyPoseCapture(
            schema: "com.gravitas.rotomotion.smoothed_meshy24.v0",
            sourceNormalizedCapturePath: nil,
            smoothingSettings: settings,
            frames: outputFrames
        )
    }

    private static func weightedAverage(
        jointName: String,
        centerFrameIndex: Int,
        frameByIndex: [Int: NormalizedMeshyPoseCapture.Frame],
        settings: SmoothedMeshyPoseCapture.SmoothingSettings
    ) -> (x: Double, y: Double) {
        guard let centerFrame = frameByIndex[centerFrameIndex],
              let centerJoint = centerFrame.joints[jointName] else {
            return (0.5, 0.5)
        }

        let radius = max(1, settings.windowRadius)
        let strength = max(0.0, min(settings.strength, 1.0))

        var weightedX = 0.0
        var weightedY = 0.0
        var totalWeight = 0.0

        for offset in -radius...radius {
            let candidateFrameIndex = centerFrameIndex + offset

            guard let candidateFrame = frameByIndex[candidateFrameIndex],
                  let candidateJoint = candidateFrame.joints[jointName] else {
                continue
            }

            if candidateJoint.missing && !settings.missingInterpolationEnabled {
                continue
            }

            let distance = abs(Double(offset))
            let temporalWeight = 1.0 / (1.0 + distance)
            let confidenceWeight = settings.confidenceWeighted
                ? max(0.05, min(candidateJoint.confidence, 1.0))
                : 1.0
            let missingPenalty = candidateJoint.missing ? 0.15 : 1.0
            let weight = temporalWeight * confidenceWeight * missingPenalty

            weightedX += candidateJoint.x * weight
            weightedY += candidateJoint.y * weight
            totalWeight += weight
        }

        guard totalWeight > 0.000001 else {
            return (centerJoint.x, centerJoint.y)
        }

        let averageX = weightedX / totalWeight
        let averageY = weightedY / totalWeight

        return (
            x: centerJoint.x + (averageX - centerJoint.x) * strength,
            y: centerJoint.y + (averageY - centerJoint.y) * strength
        )
    }
}
