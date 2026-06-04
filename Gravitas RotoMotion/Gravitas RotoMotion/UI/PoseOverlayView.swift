import SwiftUI

struct PoseOverlayView: View {
    let rawFrame: RawVisionPoseCapture.PoseFrame?
    let normalizedFrame: NormalizedMeshyPoseCapture.Frame?
    let smoothedFrame: SmoothedMeshyPoseCapture.Frame?
    let showRaw: Bool
    let showSmoothed: Bool
    let showSmoothingDelta: Bool

    var body: some View {
        Canvas { context, size in
            if showRaw, let rawFrame {
                drawRawVisionPoints(frame: rawFrame, context: &context, size: size)
            }

            if showSmoothingDelta, let smoothedFrame {
                drawSmoothingDeltas(frame: smoothedFrame, context: &context, size: size)
            }

            if showSmoothed, let smoothedFrame {
                drawSmoothedSkeleton(frame: smoothedFrame, context: &context, size: size)
            } else if showRaw, let normalizedFrame {
                drawNormalizedSkeleton(frame: normalizedFrame, context: &context, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawRawVisionPoints(
        frame: RawVisionPoseCapture.PoseFrame,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for joint in frame.joints.values {
            let point = point(x: joint.x, y: joint.y, size: size)
            let opacity = max(0.22, min(joint.confidence, 1.0))
            let radius = 3.5
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            context.fill(Path(ellipseIn: rect), with: .color(.yellow.opacity(opacity)))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 0.75)
        }
    }

    private func drawNormalizedSkeleton(
        frame: NormalizedMeshyPoseCapture.Frame,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let points = frame.joints.mapValues { joint in
            point(x: joint.x, y: joint.y, size: size)
        }

        for (a, b) in CanonicalRig.bonePairs {
            guard
                let pointA = points[a],
                let pointB = points[b],
                let jointA = frame.joints[a],
                let jointB = frame.joints[b]
            else {
                continue
            }

            let generated = jointA.generated || jointB.generated
            let confidence = min(jointA.confidence, jointB.confidence)
            let opacity = generated ? max(0.12, confidence * 0.4) : max(0.25, confidence)
            var path = Path()
            path.move(to: pointA)
            path.addLine(to: pointB)

            context.stroke(
                path,
                with: .color(.yellow.opacity(opacity)),
                lineWidth: generated ? 1.0 : 1.75
            )
        }
    }

    private func drawSmoothedSkeleton(
        frame: SmoothedMeshyPoseCapture.Frame,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let points = frame.joints.mapValues { joint in
            point(x: joint.smoothedX, y: joint.smoothedY, size: size)
        }

        for (a, b) in CanonicalRig.bonePairs {
            guard
                let pointA = points[a],
                let pointB = points[b],
                let jointA = frame.joints[a],
                let jointB = frame.joints[b]
            else {
                continue
            }

            let generated = jointA.generated || jointB.generated
            let confidence = min(jointA.confidence, jointB.confidence)
            let opacity = generated ? max(0.16, confidence * 0.45) : max(0.35, confidence)
            var path = Path()
            path.move(to: pointA)
            path.addLine(to: pointB)

            context.stroke(
                path,
                with: .color(.cyan.opacity(opacity)),
                lineWidth: generated ? 1.25 : 2.25
            )
        }

        for jointName in CanonicalRig.jointNames {
            guard
                let joint = frame.joints[jointName],
                let point = points[jointName]
            else {
                continue
            }

            let radius = joint.generated ? 2.5 : 4.25
            let opacity = joint.generated ? max(0.18, joint.confidence * 0.5) : max(0.45, joint.confidence)
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            context.fill(Path(ellipseIn: rect), with: .color(.cyan.opacity(opacity)))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 0.75)
        }
    }

    private func drawSmoothingDeltas(
        frame: SmoothedMeshyPoseCapture.Frame,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for joint in frame.joints.values where joint.smoothingEnabled {
            let rawPoint = point(x: joint.rawX, y: joint.rawY, size: size)
            let smoothedPoint = point(x: joint.smoothedX, y: joint.smoothedY, size: size)

            guard hypot(smoothedPoint.x - rawPoint.x, smoothedPoint.y - rawPoint.y) > 0.5 else {
                continue
            }

            var path = Path()
            path.move(to: rawPoint)
            path.addLine(to: smoothedPoint)

            context.stroke(
                path,
                with: .color(Color(red: 1.0, green: 0.0, blue: 1.0).opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4, 3])
            )
        }
    }

    private func point(x: Double, y: Double, size: CGSize) -> CGPoint {
        CGPoint(
            x: x * size.width,
            y: (1.0 - y) * size.height
        )
    }
}
