import AVFoundation
import CoreVideo
import Foundation

struct VideoFrameSample {
    let sampleIndex: Int
    let sourceFrameIndex: Int?
    let timeSeconds: Double
    let pixelBuffer: CVPixelBuffer
}

final class VideoFrameReader {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func readSamples(
        sampleFPS: Double,
        maxFrames: Int,
        onSample: @escaping (VideoFrameSample) throws -> Void
    ) async throws {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "No video track found."]
            )
        }

        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add AVAssetReaderTrackOutput."]
            )
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed to start."]
            )
        }

        let sourceFPS = Double(nominalFrameRate)
        let targetFPS = sampleFPS > 0 ? sampleFPS : max(sourceFPS, 1.0)
        let minTimeStep = 1.0 / targetFPS

        var lastAcceptedTime = -Double.infinity
        var sampleIndex = 0
        var sourceFrameIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(pts)

            defer {
                sourceFrameIndex += 1
            }

            guard timeSeconds.isFinite else {
                continue
            }

            if timeSeconds - lastAcceptedTime < minTimeStep * 0.75 {
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            try onSample(
                VideoFrameSample(
                    sampleIndex: sampleIndex,
                    sourceFrameIndex: sourceFrameIndex,
                    timeSeconds: timeSeconds,
                    pixelBuffer: pixelBuffer
                )
            )

            sampleIndex += 1
            lastAcceptedTime = timeSeconds

            if maxFrames > 0 && sampleIndex >= maxFrames {
                break
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed."]
            )
        }
    }
}
