import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class RotoMotionExporter: ObservableObject {
    @Published var isExtracting = false
    @Published var progressText = "Open a video to begin."
    @Published var capture: RawVisionPoseCapture?

    func runExtraction(
        videoURL: URL,
        sampleFPS: Double,
        maxFrames: Int
    ) async throws -> RawVisionPoseCapture {
        isExtracting = true
        progressText = "Starting Vision extraction..."

        do {
            let capture = try await Self.buildCapture(
                videoURL: videoURL,
                sampleFPS: sampleFPS,
                maxFrames: maxFrames
            ) { [weak self] text in
                Task { @MainActor in
                    self?.progressText = text
                }
            }

            self.capture = capture
            progressText = "Extraction complete: \(capture.frames.count) frames"
            isExtracting = false
            return capture
        } catch {
            progressText = "Extraction failed: \(error.localizedDescription)"
            isExtracting = false
            throw error
        }
    }

    func runExtraction(
        frames: [VideoFrame],
        sourceURL: URL,
        eyeLabel: String,
        nominalFPS: Double
    ) async throws -> RawVisionPoseCapture {
        isExtracting = true
        progressText = "Starting \(eyeLabel) eye Vision extraction..."

        do {
            let capture = try await Self.buildCapture(
                frames: frames,
                sourceURL: sourceURL,
                eyeLabel: eyeLabel,
                nominalFPS: nominalFPS
            ) { [weak self] text in
                Task { @MainActor in
                    self?.progressText = text
                }
            }

            self.capture = capture
            progressText = "\(eyeLabel) eye extraction complete: \(capture.frames.count) frames"
            isExtracting = false
            return capture
        } catch {
            progressText = "\(eyeLabel) eye extraction failed: \(error.localizedDescription)"
            isExtracting = false
            throw error
        }
    }

    private static func buildCapture(
        videoURL: URL,
        sampleFPS: Double,
        maxFrames: Int,
        progress: @escaping (String) -> Void
    ) async throws -> RawVisionPoseCapture {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: videoURL)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)

            guard let videoTrack = tracks.first else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 2001,
                    userInfo: [NSLocalizedDescriptionKey: "No video track."]
                )
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let nominalFPS = try await videoTrack.load(.nominalFrameRate)
            let extractor = VisionPoseExtractor()
            let reader = VideoFrameReader(url: videoURL)
            var frames: [RawVisionPoseCapture.PoseFrame] = []

            try await reader.readSamples(
                sampleFPS: sampleFPS,
                maxFrames: maxFrames
            ) { sample in
                let rawJoints = try extractor.extractPose(from: sample.pixelBuffer)

                frames.append(
                    RawVisionPoseCapture.PoseFrame(
                        frameIndex: sample.sampleIndex,
                        sourceFrameIndex: sample.sourceFrameIndex,
                        timeSeconds: sample.timeSeconds,
                        timecode: TimecodeFormatter.timecode(seconds: sample.timeSeconds),
                        detected: !rawJoints.isEmpty,
                        joints: rawJoints
                    )
                )

                progress("Extracted \(frames.count) frames")
            }

            return RawVisionPoseCapture(
                schema: "com.gravitas.rotomotion.raw_vision.v0",
                appName: "Gravitas RotoMotion",
                appVersion: "0.1.0",
                sourceVideo: .init(
                    fileName: videoURL.lastPathComponent,
                    filePath: videoURL.path,
                    durationSeconds: CMTimeGetSeconds(duration),
                    nominalFrameRate: Double(nominalFPS),
                    naturalWidth: Int(naturalSize.width.rounded()),
                    naturalHeight: Int(naturalSize.height.rounded())
                ),
                extraction: .init(
                    visionRequest: "VNDetectHumanBodyPoseRequest",
                    sampleFPS: sampleFPS,
                    normalizedCoordinates: true,
                    createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
                    notes: "Raw Vision evidence only. No smoothing, rig fitting, or semantic interpretation."
                ),
                frames: frames
            )
        }.value
    }

    private static func buildCapture(
        frames: [VideoFrame],
        sourceURL: URL,
        eyeLabel: String,
        nominalFPS: Double,
        progress: @escaping (String) -> Void
    ) async throws -> RawVisionPoseCapture {
        try await Task.detached(priority: .userInitiated) {
            let extractor = VisionPoseExtractor()
            var poseFrames: [RawVisionPoseCapture.PoseFrame] = []
            poseFrames.reserveCapacity(frames.count)

            for frame in frames {
                let rawJoints = try extractor.extractPose(from: frame.pixelBuffer)

                poseFrames.append(
                    RawVisionPoseCapture.PoseFrame(
                        frameIndex: frame.frameIndex,
                        sourceFrameIndex: frame.frameIndex,
                        timeSeconds: frame.timeSeconds,
                        timecode: TimecodeFormatter.timecode(seconds: frame.timeSeconds),
                        detected: !rawJoints.isEmpty,
                        joints: rawJoints
                    )
                )

                if poseFrames.count % 10 == 0 {
                    progress("Extracted \(eyeLabel) eye \(poseFrames.count) / \(frames.count) frames")
                }
            }

            let firstImage = frames.first?.image
            let width = Int((firstImage?.size.width ?? 0).rounded())
            let height = Int((firstImage?.size.height ?? 0).rounded())
            let duration = max(
                (frames.last?.timeSeconds ?? 0) - (frames.first?.timeSeconds ?? 0),
                0
            )

            return RawVisionPoseCapture(
                schema: "com.gravitas.rotomotion.raw_vision.v0",
                appName: "Gravitas RotoMotion",
                appVersion: "0.1.0",
                sourceVideo: .init(
                    fileName: "\(sourceURL.lastPathComponent) [\(eyeLabel) eye]",
                    filePath: sourceURL.path,
                    durationSeconds: duration,
                    nominalFrameRate: nominalFPS,
                    naturalWidth: width,
                    naturalHeight: height
                ),
                extraction: .init(
                    visionRequest: "VNDetectHumanBodyPoseRequest",
                    sampleFPS: nominalFPS,
                    normalizedCoordinates: true,
                    createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
                    notes: "Spatial \(eyeLabel) eye Vision evidence. No smoothing, rig fitting, or semantic interpretation."
                ),
                frames: poseFrames
            )
        }.value
    }
}
