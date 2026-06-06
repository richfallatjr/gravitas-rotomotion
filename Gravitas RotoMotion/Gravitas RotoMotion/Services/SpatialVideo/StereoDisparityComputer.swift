import Foundation

enum StereoDisparityComputer {
    static func computeFrame(
        frameIndex: Int,
        timeSeconds: Double,
        left: StereoLuminanceBuffer,
        right: StereoLuminanceBuffer,
        metadata: SpatialVideoCameraMetadata,
        settings: StereoDisparitySettings
    ) throws -> SpatialDisparityMapCapture.Frame {
        guard left.width == right.width,
              left.height == right.height else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 2001,
                userInfo: [
                    NSLocalizedDescriptionKey: "Left/right luminance buffers differ in size."
                ]
            )
        }

        guard let baseline = metadata.baselineMeters,
              let horizontalFOV = metadata.horizontalFOVDegrees,
              baseline > 0,
              horizontalFOV > 0 else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 2002,
                userInfo: [
                    NSLocalizedDescriptionKey: "Missing baseline or horizontal FOV for disparity depth conversion."
                ]
            )
        }

        let width = left.width
        let height = left.height
        let fovRadians = horizontalFOV * .pi / 180.0
        let focalPixels = 0.5 * Double(width) / tan(fovRadians * 0.5)

        var disparity = [Float](repeating: .nan, count: width * height)
        var depth = [Float](repeating: .nan, count: width * height)
        var confidence = [Float](repeating: 0, count: width * height)

        let radius = max(1, settings.patchRadius)
        let search = max(1, settings.searchRadius)
        let step = max(1, settings.searchStep)

        guard width > radius * 2 + search * 2,
              height > radius * 2 else {
            throw NSError(
                domain: "RotoMotionDisparity",
                code: 2003,
                userInfo: [
                    NSLocalizedDescriptionKey: "Image too small for disparity settings."
                ]
            )
        }

        let pixelCount = Double((radius * 2 + 1) * (radius * 2 + 1))
        var bestDx = [Int](repeating: 0, count: width * height)
        var bestCost = [Double](repeating: .greatestFiniteMagnitude, count: width * height)
        var secondBest = [Double](repeating: .greatestFiniteMagnitude, count: width * height)

        for dx in stride(from: -search, through: search, by: step) {
            let integral = absoluteDifferenceIntegral(
                left: left,
                right: right,
                dx: dx
            )

            for y in radius..<(height - radius) {
                for x in (radius + search)..<(width - radius - search) {
                    let xRight = x - dx

                    guard xRight >= radius,
                          xRight < width - radius else {
                        continue
                    }

                    let cost = boxSum(
                        integral,
                        width: width,
                        x0: x - radius,
                        y0: y - radius,
                        x1: x + radius,
                        y1: y + radius
                    )
                    let index = y * width + x

                    if cost < bestCost[index] {
                        secondBest[index] = bestCost[index]
                        bestCost[index] = cost
                        bestDx[index] = dx
                    } else if cost < secondBest[index] {
                        secondBest[index] = cost
                    }
                }
            }
        }

        for y in radius..<(height - radius) {
            for x in (radius + search)..<(width - radius - search) {
                let index = y * width + x
                let dx = bestDx[index]
                let normalizedCost = bestCost[index] / pixelCount
                let uniqueness = secondBest[index].isFinite && secondBest[index] > 0
                    ? max(0.0, min(1.0, 1.0 - bestCost[index] / secondBest[index]))
                    : 0.0

                guard normalizedCost <= settings.maxMatchCost,
                      abs(dx) > 0 else {
                    continue
                }

                let disparityPixels = Float(dx)
                let depthMeters = focalPixels * baseline / abs(Double(dx))

                disparity[index] = disparityPixels
                depth[index] = Float(depthMeters)
                confidence[index] = Float(max(0.0, min(1.0, (1.0 - normalizedCost) * (0.5 + uniqueness))))
            }
        }

        return SpatialDisparityMapCapture.Frame(
            frameIndex: frameIndex,
            timeSeconds: timeSeconds,
            width: width,
            height: height,
            disparityPixels: disparity,
            depthMeters: depth,
            confidence: confidence,
            previewPNGPath: nil
        )
    }

    private static func absoluteDifferenceIntegral(
        left: StereoLuminanceBuffer,
        right: StereoLuminanceBuffer,
        dx: Int
    ) -> [Double] {
        let width = left.width
        let height = left.height
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))

        for y in 0..<height {
            var rowSum = 0.0

            for x in 0..<width {
                let xRight = x - dx
                let diff: Double

                if xRight >= 0,
                   xRight < width {
                    let index = y * width + x
                    diff = Double(abs(left.pixels[index] - right.pixels[y * width + xRight]))
                } else {
                    diff = 1.0
                }

                rowSum += diff
                integral[(y + 1) * (width + 1) + (x + 1)] = integral[y * (width + 1) + (x + 1)] + rowSum
            }
        }

        return integral
    }

    private static func boxSum(
        _ integral: [Double],
        width: Int,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) -> Double {
        let stride = width + 1
        let ix0 = x0
        let iy0 = y0
        let ix1 = x1 + 1
        let iy1 = y1 + 1

        return integral[iy1 * stride + ix1]
            - integral[iy0 * stride + ix1]
            - integral[iy1 * stride + ix0]
            + integral[iy0 * stride + ix0]
    }
}
