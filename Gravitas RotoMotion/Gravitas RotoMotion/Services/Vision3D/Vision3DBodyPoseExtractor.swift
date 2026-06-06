import AppKit
import Foundation
import simd
import Vision

struct Vision3DInputFrame {
    let frameIndex: Int
    let timeSeconds: Double
    let image: NSImage
}

enum Vision3DBodyPoseExtractor {
    static func extract(
        frames: [Vision3DInputFrame]
    ) async throws -> Vision3DBodyPoseCapture {
        guard #available(macOS 14.0, *) else {
            throw NSError(
                domain: "GravitasRotoMotion.Vision3D",
                code: 3001,
                userInfo: [NSLocalizedDescriptionKey: "Vision 3D body pose requires macOS 14 or newer."]
            )
        }

        var outputFrames: [Vision3DBodyPoseCapture.Frame] = []
        outputFrames.reserveCapacity(frames.count)

        for frame in frames {
            let result = try autoreleasepool {
                try extractFrame(frame)
            }

            outputFrames.append(result)

            if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
                print("""
                [Vision3D] extracted frame
                  frame: \(frame.frameIndex)
                  time: \(String(format: "%.3f", frame.timeSeconds))
                  valid: \(result.valid)
                  joints: \(result.joints.count)
                  bodyHeightMeters: \(result.bodyHeightMeters ?? -1)
                  status: \(result.status)
                """)
            }
        }

        return Vision3DBodyPoseCapture(
            schema: Vision3DBodyPoseCapture.currentSchema,
            frames: outputFrames
        )
    }

    @available(macOS 14.0, *)
    private static func extractFrame(
        _ frame: Vision3DInputFrame
    ) throws -> Vision3DBodyPoseCapture.Frame {
        guard let cgImage = frame.image.cgImageForVision3D() else {
            return Vision3DBodyPoseCapture.Frame(
                frameIndex: frame.frameIndex,
                timeSeconds: frame.timeSeconds,
                joints: [:],
                bodyHeightMeters: nil,
                heightEstimation: nil,
                cameraOriginMatrix: nil,
                valid: false,
                status: "missing CGImage"
            )
        }

        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )

        try handler.perform([request])

        guard let observation = request.results?.first else {
            return Vision3DBodyPoseCapture.Frame(
                frameIndex: frame.frameIndex,
                timeSeconds: frame.timeSeconds,
                joints: [:],
                bodyHeightMeters: nil,
                heightEstimation: nil,
                cameraOriginMatrix: nil,
                valid: false,
                status: "no 3D body observation"
            )
        }

        return try convertObservation(
            observation,
            frame: frame
        )
    }

    @available(macOS 14.0, *)
    private static func convertObservation(
        _ observation: VNHumanBodyPose3DObservation,
        frame: Vision3DInputFrame
    ) throws -> Vision3DBodyPoseCapture.Frame {
        var joints: [String: Vision3DBodyPoseCapture.Joint] = [:]

        for jointName in observation.availableJointNames {
            guard let point = try? observation.recognizedPoint(jointName) else {
                continue
            }

            let rawName = jointName.rawValue.rawValue
            let position = matrixTranslation(point.position)
            let local = matrixTranslation(point.localPosition)
            let projected = try? observation.pointInImage(jointName)
            let parent = observation.parentJointName(jointName)
            let confidence = Double(observation.confidence)

            joints[rawName] = Vision3DBodyPoseCapture.Joint(
                name: rawName,
                positionXYZMeters: [
                    Double(position.x),
                    Double(position.y),
                    Double(position.z)
                ],
                localPositionXYZMeters: [
                    Double(local.x),
                    Double(local.y),
                    Double(local.z)
                ],
                projectedX: projected.map { Double($0.x) },
                projectedY: projected.map { Double($0.y) },
                confidence: confidence,
                parentName: parent?.rawValue.rawValue,
                valid: confidence > 0
            )
        }

        if frame.frameIndex == 0 {
            print("""
            [Vision3D] raw Apple joint names
              count: \(joints.count)
              names: \(joints.keys.sorted().joined(separator: ", "))
              heightEstimation: \(observation.heightEstimation.rawValue)
              bodyHeightMeters: \(observation.bodyHeight)
            """)
        }

        return Vision3DBodyPoseCapture.Frame(
            frameIndex: frame.frameIndex,
            timeSeconds: frame.timeSeconds,
            joints: joints,
            bodyHeightMeters: Double(observation.bodyHeight),
            heightEstimation: "\(observation.heightEstimation.rawValue)",
            cameraOriginMatrix: flatten(observation.cameraOriginMatrix),
            valid: !joints.isEmpty,
            status: joints.isEmpty ? "no recognized 3D joints" : "ok"
        )
    }

    private static func matrixTranslation(
        _ m: simd_float4x4
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            m.columns.3.x,
            m.columns.3.y,
            m.columns.3.z
        )
    }

    private static func flatten(
        _ m: simd_float4x4
    ) -> [Double] {
        [
            Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z), Double(m.columns.0.w),
            Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z), Double(m.columns.1.w),
            Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z), Double(m.columns.2.w),
            Double(m.columns.3.x), Double(m.columns.3.y), Double(m.columns.3.z), Double(m.columns.3.w)
        ]
    }
}

private extension NSImage {
    func cgImageForVision3D() -> CGImage? {
        var rect = CGRect(
            origin: .zero,
            size: size
        )

        return cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        )
    }
}
