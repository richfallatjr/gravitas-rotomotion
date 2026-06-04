import SwiftUI

struct RigOverlayView: View {
    let frame: RigFitResult.FrameFit?
    let projectionSettings: RigProjectionSettings

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }

            let projected = RigProjector.project(
                fittedPose: frame,
                settings: projectionSettings
            )
            let points = projected.mapValues {
                CGPoint(
                    x: $0.x * size.width,
                    y: $0.y * size.height
                )
            }

            for (a, b) in CanonicalRig.bonePairs {
                guard let pointA = points[a], let pointB = points[b] else {
                    continue
                }

                var path = Path()
                path.move(to: pointA)
                path.addLine(to: pointB)

                context.stroke(
                    path,
                    with: .color(.green.opacity(0.8)),
                    lineWidth: 2.25
                )
            }

            for jointName in CanonicalRig.jointNames {
                guard let point = points[jointName] else { continue }

                let radius = jointName == "Hips" ? 4.5 : 3.25
                let rect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.fill(Path(ellipseIn: rect), with: .color(.green.opacity(0.95)))
                context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.45)), lineWidth: 0.75)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
