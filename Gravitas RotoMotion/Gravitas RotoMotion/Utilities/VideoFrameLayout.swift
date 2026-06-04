import CoreGraphics
import Foundation

struct VideoFrameLayout: Equatable {
    let cardSize: CGSize
    let imageSize: CGSize
    let fittedRect: CGRect

    var aspectRatio: CGFloat {
        guard imageSize.height > 0 else {
            return 9.0 / 16.0
        }

        return imageSize.width / imageSize.height
    }

    static func aspectFit(
        imageSize: CGSize,
        in cardSize: CGSize
    ) -> VideoFrameLayout {
        guard imageSize.width > 0,
              imageSize.height > 0,
              cardSize.width > 0,
              cardSize.height > 0 else {
            return VideoFrameLayout(
                cardSize: cardSize,
                imageSize: imageSize,
                fittedRect: CGRect(origin: .zero, size: cardSize)
            )
        }

        let imageAspect = imageSize.width / imageSize.height
        let cardAspect = cardSize.width / cardSize.height

        let fittedSize: CGSize

        if imageAspect > cardAspect {
            fittedSize = CGSize(
                width: cardSize.width,
                height: cardSize.width / imageAspect
            )
        } else {
            fittedSize = CGSize(
                width: cardSize.height * imageAspect,
                height: cardSize.height
            )
        }

        let origin = CGPoint(
            x: (cardSize.width - fittedSize.width) * 0.5,
            y: (cardSize.height - fittedSize.height) * 0.5
        )

        return VideoFrameLayout(
            cardSize: cardSize,
            imageSize: imageSize,
            fittedRect: CGRect(origin: origin, size: fittedSize)
        )
    }

    func pointFromNormalizedVision(
        x: Double,
        y: Double
    ) -> CGPoint {
        CGPoint(
            x: fittedRect.minX + CGFloat(x) * fittedRect.width,
            y: fittedRect.minY + CGFloat(1.0 - y) * fittedRect.height
        )
    }
}
