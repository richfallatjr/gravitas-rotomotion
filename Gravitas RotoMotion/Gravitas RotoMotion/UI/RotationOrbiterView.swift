import SwiftUI

struct RotationOrbiterView: View {
    let onDragDelta: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    let onCommit: () -> Void

    @State private var lastPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)

            ZStack {
                Circle()
                    .stroke(.secondary, lineWidth: 2)
                    .frame(width: size * 0.85, height: size * 0.85)

                Text("Drag to rotate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let lastPoint {
                            onDragDelta(
                                value.location.x - lastPoint.x,
                                value.location.y - lastPoint.y
                            )
                        }

                        lastPoint = value.location
                    }
                    .onEnded { _ in
                        lastPoint = nil
                        onCommit()
                    }
            )
        }
    }
}
