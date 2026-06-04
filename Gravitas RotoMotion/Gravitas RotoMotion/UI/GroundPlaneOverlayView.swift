import SwiftUI

struct GroundPlaneOverlayView: View {
    let groundPlane: GroundPlaneController

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                drawGroundPlane(
                    context: &context,
                    size: size
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawGroundPlane(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let center = CGPoint(
            x: size.width * (0.5 + groundPlane.offsetX * 0.35),
            y: size.height * (0.70 + groundPlane.offsetY * 0.35)
        )
        let baseWidth = CGFloat(groundPlane.size) * size.width * 0.20
        let baseDepth = CGFloat(groundPlane.size) * size.height * 0.13
        let tumble = groundPlane.tumbleXRadians
        let roll = groundPlane.rollZRadians
        let depthProjection = max(0.05, abs(cos(tumble)))
        let depth = baseDepth * depthProjection
        let pitchShift = CGFloat(sin(tumble)) * baseDepth * 0.35

        var localCorners = [
            CGPoint(x: -baseWidth * 0.5, y: -depth * 0.5 + pitchShift),
            CGPoint(x: baseWidth * 0.5, y: -depth * 0.5 + pitchShift),
            CGPoint(x: baseWidth * 0.5, y: depth * 0.5 - pitchShift),
            CGPoint(x: -baseWidth * 0.5, y: depth * 0.5 - pitchShift)
        ]

        localCorners = localCorners.map { rotate($0, radians: roll) }

        let corners = localCorners.map {
            CGPoint(
                x: center.x + $0.x,
                y: center.y + $0.y
            )
        }

        var planePath = Path()
        planePath.move(to: corners[0])
        planePath.addLine(to: corners[1])
        planePath.addLine(to: corners[2])
        planePath.addLine(to: corners[3])
        planePath.closeSubpath()

        context.fill(
            planePath,
            with: .color(.green.opacity(groundPlane.opacity * 0.45))
        )
        context.stroke(
            planePath,
            with: .color(.green.opacity(0.95)),
            lineWidth: 2.0
        )

        drawGrid(
            context: &context,
            corners: corners,
            opacity: groundPlane.opacity
        )
        drawCenterLine(
            context: &context,
            corners: corners
        )
    }

    private func drawGrid(
        context: inout GraphicsContext,
        corners: [CGPoint],
        opacity: Double
    ) {
        guard corners.count == 4 else { return }

        for i in 1..<4 {
            let t = CGFloat(i) / 4.0
            let a = lerp(corners[0], corners[3], t)
            let b = lerp(corners[1], corners[2], t)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(
                path,
                with: .color(.green.opacity(opacity * 0.45)),
                lineWidth: 1
            )
        }

        for i in 1..<4 {
            let t = CGFloat(i) / 4.0
            let a = lerp(corners[0], corners[1], t)
            let b = lerp(corners[3], corners[2], t)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(
                path,
                with: .color(.green.opacity(opacity * 0.45)),
                lineWidth: 1
            )
        }
    }

    private func drawCenterLine(
        context: inout GraphicsContext,
        corners: [CGPoint]
    ) {
        let left = lerp(corners[0], corners[3], 0.5)
        let right = lerp(corners[1], corners[2], 0.5)

        var path = Path()
        path.move(to: left)
        path.addLine(to: right)
        context.stroke(
            path,
            with: .color(.white.opacity(0.7)),
            lineWidth: 1.5
        )
    }

    private func rotate(
        _ point: CGPoint,
        radians: Double
    ) -> CGPoint {
        let c = CGFloat(cos(radians))
        let s = CGFloat(sin(radians))

        return CGPoint(
            x: point.x * c - point.y * s,
            y: point.x * s + point.y * c
        )
    }

    private func lerp(
        _ a: CGPoint,
        _ b: CGPoint,
        _ t: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t
        )
    }
}
