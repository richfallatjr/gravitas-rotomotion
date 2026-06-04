import SwiftUI

struct PoseOverlayView: View {
    let layout: VideoFrameLayout

    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?

    let showRawVisionPoints: Bool
    let showNormalizedMeshyPoints: Bool
    let showSmoothedMeshyPoints: Bool
    let showSmoothingDeltaVectors: Bool

    var body: some View {
        Canvas { context, _ in
            var imageRectPath = Path()
            imageRectPath.addRect(layout.fittedRect)

            context.stroke(
                imageRectPath,
                with: .color(.white.opacity(0.18)),
                lineWidth: 1
            )

            if showRawVisionPoints, let rawFrame {
                drawRawVisionPoints(frame: rawFrame, context: &context)
            }

            if showNormalizedMeshyPoints, let normalizedFrame {
                drawNormalizedMeshySkeleton(frame: normalizedFrame, context: &context)
            }

            if showSmoothingDeltaVectors, let smoothedFrame {
                drawSmoothingDeltas(frame: smoothedFrame, context: &context)
            }

            if showSmoothedMeshyPoints, let smoothedFrame {
                drawSmoothedMeshySkeleton(frame: smoothedFrame, context: &context)
            }
        }
        .allowsHitTesting(false)
        .background(Color.clear)
        .accessibilityHidden(true)
    }

    private func drawRawVisionPoints(
        frame: RawVisionPoseCapture.PoseFrame,
        context: inout GraphicsContext
    ) {
        for joint in frame.joints.values {
            let point = point(x: joint.x, y: joint.y)
            let opacity = max(0.25, min(joint.confidence, 1.0))
            drawCircle(
                point: point,
                radius: 3.25,
                color: .orange.opacity(opacity),
                context: &context
            )
        }
    }

    private func drawNormalizedMeshySkeleton(
        frame: NormalizedMeshyPoseCapture.Frame,
        context: inout GraphicsContext
    ) {
        for (a, b) in CanonicalRig.bonePairs {
            guard
                let jointA = frame.joints[a],
                let jointB = frame.joints[b]
            else {
                continue
            }

            let missing = jointA.missing || jointB.missing
            let generated = jointA.generated || jointB.generated
            let opacity = missing ? 0.18 : (generated ? 0.35 : 0.72)
            drawLine(
                from: point(x: jointA.x, y: jointA.y),
                to: point(x: jointB.x, y: jointB.y),
                color: Color.yellow.opacity(opacity),
                lineWidth: generated ? 1.1 : 1.7,
                context: &context
            )
        }

        for jointName in CanonicalRig.jointNames {
            guard let joint = frame.joints[jointName] else { continue }

            let p = point(x: joint.x, y: joint.y)

            if joint.missing {
                drawCross(point: p, radius: 4.0, color: .gray.opacity(0.65), context: &context)
            } else {
                drawCircle(
                    point: p,
                    radius: joint.generated ? 2.75 : 4.0,
                    color: Color.yellow.opacity(joint.generated ? 0.45 : 0.9),
                    context: &context
                )
            }
        }
    }

    private func drawSmoothedMeshySkeleton(
        frame: SmoothedMeshyPoseCapture.Frame,
        context: inout GraphicsContext
    ) {
        for (a, b) in CanonicalRig.bonePairs {
            guard
                let jointA = frame.joints[a],
                let jointB = frame.joints[b]
            else {
                continue
            }

            let missing = jointA.missing || jointB.missing
            let generated = jointA.generated || jointB.generated
            let opacity = missing ? 0.2 : (generated ? 0.55 : 0.95)
            drawLine(
                from: point(x: jointA.smoothedX, y: jointA.smoothedY),
                to: point(x: jointB.smoothedX, y: jointB.smoothedY),
                color: Color.cyan.opacity(opacity),
                lineWidth: generated ? 1.35 : 2.35,
                context: &context
            )
        }

        for jointName in CanonicalRig.jointNames {
            guard let joint = frame.joints[jointName] else { continue }

            let p = point(x: joint.smoothedX, y: joint.smoothedY)

            if joint.missing {
                drawCross(point: p, radius: 4.5, color: Color.cyan.opacity(0.35), context: &context)
            } else {
                drawCircle(
                    point: p,
                    radius: joint.generated ? 3.0 : 5.0,
                    color: Color.cyan.opacity(joint.generated ? 0.55 : 1.0),
                    context: &context
                )
            }
        }
    }

    private func drawSmoothingDeltas(
        frame: SmoothedMeshyPoseCapture.Frame,
        context: inout GraphicsContext
    ) {
        let deltaColor = Color(red: 1.0, green: 0.0, blue: 1.0)

        for joint in frame.joints.values where joint.smoothingEnabled && !joint.missing {
            let raw = point(x: joint.rawX, y: joint.rawY)
            let smooth = point(x: joint.smoothedX, y: joint.smoothedY)
            let deltaLength = hypot(smooth.x - raw.x, smooth.y - raw.y)

            guard deltaLength > 0.5 else { continue }

            drawLine(
                from: raw,
                to: smooth,
                color: deltaColor.opacity(0.85),
                lineWidth: 1.25,
                context: &context
            )
            drawArrowHead(
                from: raw,
                to: smooth,
                color: deltaColor.opacity(0.85),
                context: &context
            )
        }
    }

    private func point(x: Double, y: Double) -> CGPoint {
        layout.pointFromNormalizedVision(x: x, y: y)
    }

    private func drawCircle(
        point: CGPoint,
        radius: CGFloat,
        color: Color,
        context: inout GraphicsContext
    ) {
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        context.fill(Path(ellipseIn: rect), with: .color(color))
        context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.45)), lineWidth: 0.7)
    }

    private func drawCross(
        point: CGPoint,
        radius: CGFloat,
        color: Color,
        context: inout GraphicsContext
    ) {
        var a = Path()
        a.move(to: CGPoint(x: point.x - radius, y: point.y - radius))
        a.addLine(to: CGPoint(x: point.x + radius, y: point.y + radius))

        var b = Path()
        b.move(to: CGPoint(x: point.x + radius, y: point.y - radius))
        b.addLine(to: CGPoint(x: point.x - radius, y: point.y + radius))

        context.stroke(a, with: .color(color), lineWidth: 1.2)
        context.stroke(b, with: .color(color), lineWidth: 1.2)
    }

    private func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        lineWidth: CGFloat,
        context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func drawArrowHead(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        context: inout GraphicsContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let arrowLength: CGFloat = 6.0
        let side: CGFloat = 3.0

        let left = CGPoint(
            x: end.x - ux * arrowLength - uy * side,
            y: end.y - uy * arrowLength + ux * side
        )
        let right = CGPoint(
            x: end.x - ux * arrowLength + uy * side,
            y: end.y - uy * arrowLength - ux * side
        )

        var path = Path()
        path.move(to: end)
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
        )
    }
}
