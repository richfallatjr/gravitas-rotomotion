import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum SpatialVideoFrameDecoder {
    static func decodeLeftRightFrames(
        url: URL,
        maxFrames: Int = 0,
        maximumImageDimension: CGFloat = 1280,
        metadataOverride: SpatialVideoCameraMetadata? = nil
    ) async throws -> SpatialDecodedFrames {
        if #unavailable(macOS 14.0) {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7301,
                userInfo: [NSLocalizedDescriptionKey: "MV-HEVC tagged-buffer decoding requires macOS 14 or newer."]
            )
        }

        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7302,
                userInfo: [NSLocalizedDescriptionKey: "Spatial video has no video track."]
            )
        }

        var metadata = try await SpatialVideoMetadataReader.readMetadata(url: url)
        if let metadataOverride {
            metadata.baselineMeters = metadataOverride.baselineMeters ?? metadata.baselineMeters
            metadata.horizontalFOVDegrees = metadataOverride.horizontalFOVDegrees ?? metadata.horizontalFOVDegrees
            metadata.verticalFOVDegrees = metadataOverride.verticalFOVDegrees ?? metadata.verticalFOVDegrees
            metadata.disparityAdjustment = metadataOverride.disparityAdjustment ?? metadata.disparityAdjustment
        }

        let nominalFPS = Double(try await track.load(.nominalFrameRate))
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
                code: 7303,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add spatial AVAssetReaderTrackOutput."]
            )
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 7304,
                userInfo: [NSLocalizedDescriptionKey: "Spatial AVAssetReader failed to start."]
            )
        }

        let ciContext = CIContext(options: nil)
        var leftFrames: [VideoFrame] = []
        var rightFrames: [VideoFrame] = []
        var frameIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(pts)

            guard timeSeconds.isFinite else {
                continue
            }

            guard let taggedBuffers = sampleBuffer.taggedBuffers else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 7305,
                    userInfo: [NSLocalizedDescriptionKey: "Sample buffer contains no MV-HEVC tagged buffers."]
                )
            }

            var leftFrame: VideoFrame?
            var rightFrame: VideoFrame?

            for taggedBuffer in taggedBuffers {
                guard case let .pixelBuffer(pixelBuffer) = taggedBuffer.buffer else {
                    continue
                }

                let image = makeImage(
                    from: pixelBuffer,
                    context: ciContext,
                    maximumImageDimension: maximumImageDimension
                )

                guard let image else {
                    continue
                }

                let frame = VideoFrame(
                    id: frameIndex,
                    frameIndex: frameIndex,
                    timeSeconds: timeSeconds,
                    image: image,
                    pixelBuffer: pixelBuffer
                )

                if taggedBuffer.tags.contains(.stereoView(.leftEye)) {
                    leftFrame = frame
                } else if taggedBuffer.tags.contains(.stereoView(.rightEye)) {
                    rightFrame = frame
                }
            }

            if let leftFrame, let rightFrame {
                leftFrames.append(leftFrame)
                rightFrames.append(rightFrame)
                frameIndex += 1
            }

            if maxFrames > 0 && leftFrames.count >= maxFrames {
                break
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 7306,
                userInfo: [NSLocalizedDescriptionKey: "Spatial AVAssetReader failed."]
            )
        }

        guard !leftFrames.isEmpty, leftFrames.count == rightFrames.count else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 7307,
                userInfo: [NSLocalizedDescriptionKey: "No synchronized left/right spatial frames were decoded."]
            )
        }

        return SpatialDecodedFrames(
            leftFrames: leftFrames,
            rightFrames: rightFrames,
            fps: nominalFPS.isFinite && nominalFPS > 0 ? nominalFPS : estimatedFPS(frames: leftFrames),
            duration: durationSeconds.isFinite ? durationSeconds : 0,
            metadata: metadata
        )
    }

    private static func makeImage(
        from pixelBuffer: CVPixelBuffer,
        context: CIContext,
        maximumImageDimension: CGFloat
    ) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let maxDimension = max(extent.width, extent.height)
        let scale = maxDimension > maximumImageDimension
            ? maximumImageDimension / maxDimension
            : 1.0

        let scaledImage = scale == 1.0
            ? ciImage
            : ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(
            scaledImage,
            from: scaledImage.extent
        ) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func estimatedFPS(frames: [VideoFrame]) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }
}
