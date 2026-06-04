import AVFoundation
import AVKit
import SwiftUI

struct VideoPoseViewport: View {
    let player: AVPlayer?
    let videoURL: URL?
    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let fitFrame: RigFitResult.FrameFit?
    let videoSize: CGSize
    let showRawVisionPoints: Bool
    let showNormalizedMeshyPoints: Bool
    let showSmoothedMeshyPoints: Bool
    let showSmoothingDeltaVectors: Bool
    let showFittedRig: Bool
    let projectionSettings: RigProjectionSettings
    let onTimeChange: (Double) -> Void

    @State private var timeObserver: Any?
    @State private var observedPlayer: AVPlayer?

    var body: some View {
        GeometryReader { proxy in
            let rect = fittedVideoRect(
                in: CGRect(origin: .zero, size: proxy.size),
                videoSize: videoSize
            )

            ZStack {
                Color.black

                if let player {
                    VideoPlayer(player: player)
                        .background(Color.black)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 42, weight: .regular))
                        Text("Open a video")
                            .font(.title3)
                    }
                    .foregroundStyle(.secondary)
                }

                PoseOverlayView(
                    rawFrame: rawFrame,
                    normalizedFrame: normalizedFrame,
                    smoothedFrame: smoothedFrame,
                    showRawVisionPoints: showRawVisionPoints,
                    showNormalizedMeshyPoints: showNormalizedMeshyPoints,
                    showSmoothedMeshyPoints: showSmoothedMeshyPoints,
                    showSmoothingDeltaVectors: showSmoothingDeltaVectors
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

                if showFittedRig {
                    RigOverlayView(
                        frame: fitFrame,
                        projectionSettings: projectionSettings
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .onAppear(perform: installTimeObserver)
        .onChange(of: videoURL) {
            installTimeObserver()
        }
        .onDisappear(perform: removeTimeObserver)
    }

    private func installTimeObserver() {
        removeTimeObserver()

        guard let player else { return }

        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 12.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                onTimeChange(seconds)
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }

        timeObserver = nil
        observedPlayer = nil
    }

    private func fittedVideoRect(
        in bounds: CGRect,
        videoSize: CGSize
    ) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else {
            return bounds
        }

        let videoAspect = videoSize.width / videoSize.height
        let boundsAspect = bounds.width / bounds.height

        if boundsAspect > videoAspect {
            let height = bounds.height
            let width = height * videoAspect
            return CGRect(
                x: bounds.midX - width / 2.0,
                y: bounds.minY,
                width: width,
                height: height
            )
        } else {
            let width = bounds.width
            let height = width / videoAspect
            return CGRect(
                x: bounds.minX,
                y: bounds.midY - height / 2.0,
                width: width,
                height: height
            )
        }
    }
}
