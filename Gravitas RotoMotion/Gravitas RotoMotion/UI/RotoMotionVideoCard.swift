import AppKit
import SwiftUI

struct RotoMotionVideoCard: View {
    let image: NSImage?
    let frameIndex: Int
    let videoTimeSeconds: Double
    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let showRawVisionPoints: Bool
    let showNormalizedMeshyPoints: Bool
    let showSmoothedMeshyPoints: Bool
    let showSmoothingDeltaVectors: Bool

    var body: some View {
        GeometryReader { proxy in
            let cardSize = proxy.size
            let imageSize = image?.size ?? CGSize(width: 9, height: 16)
            let layout = VideoFrameLayout.aspectFit(
                imageSize: imageSize,
                in: cardSize
            )

            ZStack {
                Color.black

                if let image {
                    DirectNSImageView(image: image)
                        .id(frameIndex)
                        .frame(
                            width: layout.fittedRect.width,
                            height: layout.fittedRect.height,
                            alignment: .center
                        )
                        .position(
                            x: layout.fittedRect.midX,
                            y: layout.fittedRect.midY
                        )
                        .clipped()
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
                    layout: layout,
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

                frameLabel

                layoutDebugLabel(
                    imageSize: imageSize,
                    cardSize: cardSize,
                    fittedRect: layout.fittedRect
                )
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .background(Color.black)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var frameLabel: some View {
        VStack {
            HStack {
                Text("Frame \(frameIndex)  t \(String(format: "%.3f", videoTimeSeconds))s")
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

    private func layoutDebugLabel(
        imageSize: CGSize,
        cardSize: CGSize,
        fittedRect: CGRect
    ) -> some View {
        VStack {
            Spacer()

            HStack {
                Text(
                    """
                    image \(Int(imageSize.width))x\(Int(imageSize.height))
                    card \(Int(cardSize.width))x\(Int(cardSize.height))
                    fit \(Int(fittedRect.width))x\(Int(fittedRect.height))
                    """
                )
                .font(.caption2)
                .monospaced()
                .padding(6)
                .background(Color.black.opacity(0.55))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Spacer()
            }
        }
        .padding(8)
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
