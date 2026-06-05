import AppKit
import AVFoundation
import Combine
import CoreImage
import Foundation

@MainActor
final class RotoVideoFrameCache: ObservableObject {
    struct CachedFrame: Identifiable {
        let id: Int
        let frameIndex: Int
        let timeSeconds: Double
        let image: NSImage
    }

    @Published private(set) var frames: [CachedFrame] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status = "No frames loaded."

    var frameCount: Int {
        frames.count
    }

    func image(for frameIndex: Int) -> NSImage? {
        guard frames.indices.contains(frameIndex) else { return nil }
        return frames[frameIndex].image
    }

    func timeSeconds(for frameIndex: Int) -> Double {
        guard frames.indices.contains(frameIndex) else { return 0 }
        return frames[frameIndex].timeSeconds
    }

    func clear() {
        frames.removeAll()
        status = "No frames loaded."
    }

    func loadSourceFrames(
        from url: URL,
        maxFrames: Int = 0,
        maximumImageDimension: CGFloat = 1280
    ) async {
        isLoading = true
        status = "Decoding source video frames..."
        frames.removeAll()

        do {
            let decoded = try await Self.decodeSourceFrames(
                from: url,
                maxFrames: maxFrames,
                maximumImageDimension: maximumImageDimension
            )

            frames = decoded
            status = "Decoded \(decoded.count) source frames."

            let fpsEstimate = Self.estimatedFPS(frames: decoded)

            print(
                """
                [RotoMotion VideoFrames] Decoded SOURCE frames
                  url: \(url.path)
                  frames: \(decoded.count)
                  estimatedFPS: \(String(format: "%.3f", fpsEstimate))
                  firstTime: \(decoded.first?.timeSeconds ?? -1)
                  lastTime: \(decoded.last?.timeSeconds ?? -1)
                """
            )
        } catch {
            status = "Source frame decode failed: \(error.localizedDescription)"
            print("[RotoMotion VideoFrames] SOURCE decode FAILED: \(error)")
        }

        isLoading = false
    }

    func loadFrames(
        from url: URL,
        sampleFPS: Double,
        maxFrames: Int = 0
    ) async {
        isLoading = true
        status = "Decoding video frames..."
        frames.removeAll()

        do {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)

            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 5101,
                    userInfo: [NSLocalizedDescriptionKey: "Video duration is invalid."]
                )
            }

            let fps = sampleFPS > 0 ? sampleFPS : 24.0
            let totalFrameCount = Int(ceil(durationSeconds * fps))
            let cappedFrameCount = maxFrames > 0 ? min(totalFrameCount, maxFrames) : totalFrameCount

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1280, height: 1280)

            var decoded: [CachedFrame] = []
            decoded.reserveCapacity(cappedFrameCount)

            for frameIndex in 0..<cappedFrameCount {
                let timeSeconds = Double(frameIndex) / fps
                let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)

                do {
                    let cgImage = try generator.copyCGImage(
                        at: time,
                        actualTime: nil
                    )

                    let image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )

                    decoded.append(
                        CachedFrame(
                            id: frameIndex,
                            frameIndex: frameIndex,
                            timeSeconds: timeSeconds,
                            image: image
                        )
                    )
                } catch {
                    print("[RotoMotion VideoFrames] Failed frame \(frameIndex) @ \(timeSeconds): \(error)")
                }

                if frameIndex % 10 == 0 {
                    frames = decoded
                    status = "Decoded \(decoded.count) / \(cappedFrameCount) frames"
                }
            }

            frames = decoded
            status = "Decoded \(decoded.count) frames."

            print(
                """
                [RotoMotion VideoFrames] Decoded video
                  url: \(url.path)
                  frames: \(decoded.count)
                  fps: \(fps)
                  duration: \(durationSeconds)
                """
            )
        } catch {
            status = "Frame decode failed: \(error.localizedDescription)"
            print("[RotoMotion VideoFrames] FAILED: \(error)")
        }

        isLoading = false
    }

    static func decodeSourceFrames(
        from url: URL,
        maxFrames: Int,
        maximumImageDimension: CGFloat
    ) async throws -> [CachedFrame] {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = tracks.first else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 6101,
                userInfo: [NSLocalizedDescriptionKey: "No video track found."]
            )
        }

        let preferredTransform = try await track.load(.preferredTransform)
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
                code: 6102,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add AVAssetReaderTrackOutput."]
            )
        }

        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 6103,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed to start."]
            )
        }

        let ciContext = CIContext(options: nil)
        var decoded: [CachedFrame] = []
        decoded.reserveCapacity(maxFrames > 0 ? maxFrames : 256)

        var displayFrameIndex = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeSeconds = CMTimeGetSeconds(pts)

            guard timeSeconds.isFinite else {
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: preferredTransform)

            let orientedExtent = ciImage.extent
            if orientedExtent.origin != .zero {
                ciImage = ciImage.transformed(
                    by: CGAffineTransform(
                        translationX: -orientedExtent.origin.x,
                        y: -orientedExtent.origin.y
                    )
                )
            }

            let extent = ciImage.extent
            let maxDimension = max(extent.width, extent.height)
            let scale = maxDimension > maximumImageDimension
                ? maximumImageDimension / maxDimension
                : 1.0

            let scaledImage = scale == 1.0
                ? ciImage
                : ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            guard let cgImage = ciContext.createCGImage(
                scaledImage,
                from: scaledImage.extent
            ) else {
                continue
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )

            decoded.append(
                CachedFrame(
                    id: displayFrameIndex,
                    frameIndex: displayFrameIndex,
                    timeSeconds: timeSeconds,
                    image: image
                )
            )

            displayFrameIndex += 1

            if maxFrames > 0 && decoded.count >= maxFrames {
                break
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "GravitasRotoMotion",
                code: 6104,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader failed."]
            )
        }

        return decoded.sorted { $0.timeSeconds < $1.timeSeconds }
    }

    static func estimatedFPS(frames: [CachedFrame]) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }
}
