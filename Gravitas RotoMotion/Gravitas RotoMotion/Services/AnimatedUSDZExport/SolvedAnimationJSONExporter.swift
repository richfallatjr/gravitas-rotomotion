import Foundation
import simd

enum SolvedAnimationJSONExporter {
    static func write(
        solve: RotoRayAnimationSolveResult,
        includeHipsTranslation: Bool,
        to url: URL
    ) throws {
        let sceneUnitsPerMeter = max(solve.sceneUnitsPerMeter, 0.0001)
        let firstHips = solve.frames.first?.jointPositions["Hips"] ?? SIMD3<Float>(0, 0, 0)
        var joints: [String: [[Any]]] = [:]

        for jointName in CanonicalRig.jointNames {
            var keys: [[Any]] = []

            for frame in solve.frames {
                let rotation = frame.localRotationsWXYZ[jointName] ?? SIMD4<Float>(1, 0, 0, 0)
                let translationMeters: SIMD3<Float>

                if includeHipsTranslation,
                   jointName == "Hips",
                   let hips = frame.jointPositions["Hips"] {
                    translationMeters = (hips - firstHips) / Float(sceneUnitsPerMeter)
                } else {
                    translationMeters = SIMD3<Float>(0, 0, 0)
                }

                keys.append([
                    frame.frameIndex,
                    Double(translationMeters.x),
                    Double(translationMeters.y),
                    Double(translationMeters.z),
                    0.0,
                    0.0,
                    0.0,
                    "linear",
                    [
                        Double(rotation.x),
                        Double(rotation.y),
                        Double(rotation.z),
                        Double(rotation.w)
                    ]
                ])
            }

            if !keys.isEmpty {
                joints[jointName] = keys
            }
        }

        let root: [String: Any] = [
            "schema": "com.gravitas.rotomotion.solved_animation_keys.v0",
            "sourceKind": solve.sourceKind,
            "rigID": solve.rigID,
            "rigVersion": solve.rigVersion,
            "targetHeightMeters": solve.targetHeightMeters,
            "sceneUnitsPerMeter": solve.sceneUnitsPerMeter,
            "frameCount": solve.frameCount,
            "fps": inferredFPS(solve.frames),
            "includeHipsTranslation": includeHipsTranslation,
            "joints": joints
        ]

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: url, options: .atomic)
    }

    private static func inferredFPS(
        _ frames: [RotoRayAnimationSolveResult.Frame]
    ) -> Double {
        guard let first = frames.first,
              let last = frames.last,
              frames.count > 1 else {
            return 24.0
        }

        let duration = max(last.timeSeconds - first.timeSeconds, 0.0001)
        return Double(frames.count - 1) / duration
    }
}
