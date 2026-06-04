import AppKit
import SwiftUI

struct RotoMotionVideoCard: View {
    let image: NSImage?
    let frameIndex: Int
    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let showRawVisionPoints: Bool
    let showNormalizedMeshyPoints: Bool
    let showSmoothedMeshyPoints: Bool
    let showSmoothingDeltaVectors: Bool

    var body: some View {
        ZStack {
            Color.black

            if let image {
                DirectNSImageView(image: image)
                    .id(frameIndex)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.largeTitle)

                    Text("Open a video")
                        .font(.headline)
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
            .background(Color.clear)
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Text("Frame \(frameIndex)")
                        .font(.caption2)
                        .monospacedDigit()
                        .padding(6)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    Spacer()
                }

                Spacer()
            }
            .padding(8)
        }
        .background(Color.black)
    }
}

struct DirectNSImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        print("[RotoMotion VideoDisplay] makeNSView DirectNSImageView")

        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
        view.needsDisplay = true

        print(
            """
            [RotoMotion VideoDisplay] updateNSView DirectNSImageView
              imageSize: \(image.size)
              viewBounds: \(view.bounds)
              window: \(view.window != nil)
            """
        )
    }
}
