import AppKit
import AVFoundation
import Combine
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
}
