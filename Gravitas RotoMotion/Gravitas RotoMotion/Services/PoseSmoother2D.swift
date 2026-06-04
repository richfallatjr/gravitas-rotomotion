import Foundation

enum PoseSmoother2D {
    static func smooth(
        normalized: NormalizedMeshyPoseCapture,
        settings: SmoothedMeshyPoseCapture.SmoothingSettings
    ) -> SmoothedMeshyPoseCapture {
        var jointTracks: [String: [(frameIndex: Int, x: Double, y: Double, confidence: Double, missing: Bool, generated: Bool)]] = [:]

        for frame in normalized.frames {
            for jointName in CanonicalRig.jointNames {
                guard let joint = frame.joints[jointName] else { continue }

                jointTracks[jointName, default: []].append(
                    (
                        frameIndex: frame.frameIndex,
                        x: joint.x,
                        y: joint.y,
                        confidence: joint.confidence,
                        missing: joint.missing,
                        generated: joint.generated
                    )
                )
            }
        }

        var smoothedByFrameJoint: [Int: [String: SmoothedMeshyPoseCapture.Joint]] = [:]

        for jointName in CanonicalRig.jointNames {
            guard let track = jointTracks[jointName] else { continue }

            let jointEnabled = settings.perJointEnabled[jointName] ?? true
            let smoothingEnabled = settings.globalEnabled && jointEnabled
            let preparedTrack = settings.missingInterpolationEnabled
                ? interpolateMissing(track)
                : track

            let smoothedTrack = smoothingEnabled
                ? smoothTrack(
                    preparedTrack,
                    strength: settings.strength,
                    confidenceWeighted: settings.confidenceWeighted
                )
                : preparedTrack.map { ($0.frameIndex, $0.x, $0.y) }

            for index in track.indices {
                let raw = track[index]
                let smooth = smoothedTrack[index]

                smoothedByFrameJoint[raw.frameIndex, default: [:]][jointName] = SmoothedMeshyPoseCapture.Joint(
                    rawX: raw.x,
                    rawY: raw.y,
                    smoothedX: smooth.1,
                    smoothedY: smooth.2,
                    deltaX: smooth.1 - raw.x,
                    deltaY: smooth.2 - raw.y,
                    confidence: raw.confidence,
                    smoothingEnabled: smoothingEnabled,
                    missing: raw.missing,
                    generated: raw.generated
                )
            }
        }

        let frames = normalized.frames.map { frame in
            SmoothedMeshyPoseCapture.Frame(
                frameIndex: frame.frameIndex,
                timeSeconds: frame.timeSeconds,
                timecode: frame.timecode,
                joints: smoothedByFrameJoint[frame.frameIndex] ?? [:]
            )
        }

        return SmoothedMeshyPoseCapture(
            schema: "com.gravitas.rotomotion.smoothed_meshy24.v0",
            sourceNormalizedCapturePath: nil,
            smoothingSettings: settings,
            frames: frames
        )
    }

    private static func interpolateMissing(
        _ track: [(frameIndex: Int, x: Double, y: Double, confidence: Double, missing: Bool, generated: Bool)]
    ) -> [(frameIndex: Int, x: Double, y: Double, confidence: Double, missing: Bool, generated: Bool)] {
        guard !track.isEmpty else { return [] }

        var result = track
        let validIndices = track.indices.filter { !track[$0].missing && track[$0].confidence > 0 }
        guard validIndices.count >= 2 else { return result }

        for index in track.indices where track[index].missing || track[index].confidence <= 0 {
            guard
                let previous = validIndices.last(where: { $0 < index }),
                let next = validIndices.first(where: { $0 > index })
            else {
                continue
            }

            let span = Double(next - previous)
            let t = span > 0 ? Double(index - previous) / span : 0
            let a = track[previous]
            let b = track[next]

            result[index] = (
                frameIndex: track[index].frameIndex,
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                confidence: min(a.confidence, b.confidence) * 0.25,
                missing: track[index].missing,
                generated: track[index].generated
            )
        }

        return result
    }

    private static func smoothTrack(
        _ track: [(frameIndex: Int, x: Double, y: Double, confidence: Double, missing: Bool, generated: Bool)],
        strength: Double,
        confidenceWeighted: Bool
    ) -> [(Int, Double, Double)] {
        guard !track.isEmpty else { return [] }

        let alphaBase = max(0.0, min(strength, 0.98))
        var forward: [(Int, Double, Double)] = []
        var previousX = track[0].x
        var previousY = track[0].y

        for sample in track {
            let confidenceFactor = confidenceWeighted
                ? max(0.05, min(sample.confidence, 1.0))
                : 1.0
            let alpha = alphaBase * confidenceFactor

            previousX = previousX * alpha + sample.x * (1.0 - alpha)
            previousY = previousY * alpha + sample.y * (1.0 - alpha)
            forward.append((sample.frameIndex, previousX, previousY))
        }

        var backward = Array(repeating: (0, 0.0, 0.0), count: track.count)
        var nextX = track[track.count - 1].x
        var nextY = track[track.count - 1].y

        for reverseIndex in stride(from: track.count - 1, through: 0, by: -1) {
            let sample = track[reverseIndex]
            let confidenceFactor = confidenceWeighted
                ? max(0.05, min(sample.confidence, 1.0))
                : 1.0
            let alpha = alphaBase * confidenceFactor

            nextX = nextX * alpha + sample.x * (1.0 - alpha)
            nextY = nextY * alpha + sample.y * (1.0 - alpha)
            backward[reverseIndex] = (sample.frameIndex, nextX, nextY)
        }

        return track.indices.map { index in
            let f = forward[index]
            let b = backward[index]
            return (track[index].frameIndex, (f.1 + b.1) * 0.5, (f.2 + b.2) * 0.5)
        }
    }
}
