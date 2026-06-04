import Foundation
import simd

enum SolvedAnimationJSONExporter {
    static func write(
        solve: RotoRayAnimationSolveResult,
        to url: URL
    ) throws {
        try write(
            solve: solve,
            includeHipsTranslation: true,
            to: url
        )
    }

    static func write(
        solve: RotoRayAnimationSolveResult,
        includeHipsTranslation: Bool,
        to url: URL
    ) throws {
        let sceneUnitsPerMeter = max(solve.sceneUnitsPerMeter, 0.0001)
        let firstHips = solve.frames.first?.jointPositions["Hips"] ?? SIMD3<Float>(0, 0, 0)
        var joints: [String: [[String: Any]]] = [:]

        for jointName in CanonicalRig.jointNames {
            var keys: [[String: Any]] = []
            var previousRotation: SIMD4<Float>?

            for frame in solve.frames {
                var rotation = frame.localRotationsWXYZ[jointName] ?? SIMD4<Float>(1, 0, 0, 0)

                if let previousRotation,
                   dot(previousRotation, rotation) < 0 {
                    rotation *= -1
                }

                previousRotation = rotation

                let translationMeters: SIMD3<Float>

                if includeHipsTranslation,
                   jointName == "Hips",
                   let hips = frame.jointPositions["Hips"] {
                    translationMeters = (hips - firstHips) / Float(sceneUnitsPerMeter)
                } else {
                    translationMeters = SIMD3<Float>(0, 0, 0)
                }

                let qw = rotation.x
                let qx = rotation.y
                let qy = rotation.z
                let qz = rotation.w

                var key: [String: Any] = [
                    "frame": frame.frameIndex,
                    "time": frame.timeSeconds,
                    "rotation_wxyz": [
                        Double(qw),
                        Double(qx),
                        Double(qy),
                        Double(qz)
                    ],
                    "curve": "linear"
                ]

                if includeHipsTranslation,
                   jointName == "Hips" {
                    key["translation_xyz"] = [
                        Double(translationMeters.x),
                        Double(translationMeters.y),
                        Double(translationMeters.z)
                    ]
                }

                keys.append(key)
            }

            if !keys.isEmpty {
                joints[jointName] = keys
            }
        }

        let root: [String: Any] = [
            "schema": "com.gravitas.rotomotion.solved_animation.v1",
            "sourceKind": solve.sourceKind,
            "rigID": solve.rigID,
            "rigVersion": solve.rigVersion,
            "targetHeightMeters": solve.targetHeightMeters,
            "sceneUnitsPerMeter": solve.sceneUnitsPerMeter,
            "frameCount": solve.frameCount,
            "fps": inferredFPS(solve.frames),
            "rotation_order": "wxyz",
            "translation_policy": includeHipsTranslation ? "hips_only" : "none",
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

    private static func dot(
        _ a: SIMD4<Float>,
        _ b: SIMD4<Float>
    ) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }
}
