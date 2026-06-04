import SwiftUI

struct PoseOverlayView: View {
    let frame: RawVisionPoseCapture.PoseFrame?
    let videoSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }

            let points = Dictionary(
                uniqueKeysWithValues: frame.canonicalJoints.map { jointName, joint in
                    (
                        jointName,
                        CGPoint(
                            x: joint.x * Double(size.width),
                            y: (1.0 - joint.y) * Double(size.height)
                        )
                    )
                }
            )

            for (a, b) in CanonicalRig.bonePairs {
                guard
                    let pointA = points[a],
                    let pointB = points[b],
                    let jointA = frame.canonicalJoints[a],
                    let jointB = frame.canonicalJoints[b]
                else {
                    continue
                }

                let generated = jointA.generated || jointB.generated
                let confidence = min(jointA.confidence, jointB.confidence)
                let opacity = generated ? max(0.18, confidence * 0.45) : max(0.35, confidence)
                let color = generated ? Color.orange.opacity(opacity) : Color.cyan.opacity(opacity)
                var path = Path()
                path.move(to: pointA)
                path.addLine(to: pointB)

                context.stroke(
                    path,
                    with: .color(color),
                    lineWidth: generated ? 1.25 : 2.5
                )
            }

            for jointName in CanonicalRig.jointNames {
                guard
                    let joint = frame.canonicalJoints[jointName],
                    let point = points[jointName]
                else {
                    continue
                }

                let radius = joint.generated ? 3.0 : 5.0
                let opacity = joint.generated ? max(0.18, joint.confidence * 0.55) : max(0.4, joint.confidence)
                let rect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2.0,
                    height: radius * 2.0
                )
                let color = joint.generated ? Color.orange.opacity(opacity) : Color.white.opacity(opacity)

                context.fill(Path(ellipseIn: rect), with: .color(color))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 0.75)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
