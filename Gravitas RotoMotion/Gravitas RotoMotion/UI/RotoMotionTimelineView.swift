import SwiftUI

struct RotoMotionTimelineView: View {
    let frameCount: Int
    let currentFrame: RawVisionPoseCapture.PoseFrame?
    let currentTimelineText: String
    @Binding var currentFrameIndex: Int
    let onSetFrame: (Int) -> Void

    var body: some View {
        let maxFrameIndex = max(frameCount - 1, 0)
        let sliderUpperBound = max(Double(maxFrameIndex), 1.0)
        let hasFrames = frameCount > 0

        VStack(spacing: 8) {
            HStack {
                Text(currentTimelineText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if let currentFrame {
                    Text("Frame \(currentFrame.frameIndex) / \(maxFrameIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Frame 0 / \(maxFrameIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Slider(
                value: Binding(
                    get: {
                        Double(min(max(currentFrameIndex, 0), maxFrameIndex))
                    },
                    set: { newValue in
                        onSetFrame(Int(newValue.rounded()))
                    }
                ),
                in: 0...sliderUpperBound,
                step: 1
            )
            .disabled(!hasFrames)
        }
    }
}
