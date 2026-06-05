import Foundation
import simd

enum RaySolveReferenceJSONExporter {
    static func write(
        solve: RotoRayAnimationSolveResult,
        to url: URL
    ) throws {
        let frames = solve.frames.map { frame -> [String: Any] in
            var joints: [String: [String: Any]] = [:]

            for jointName in CanonicalRig.jointNames {
                guard let position = frame.jointPositions[jointName] else {
                    continue
                }

                joints[jointName] = [
                    "worldPosition": [
                        Double(position.x),
                        Double(position.y),
                        Double(position.z)
                    ],
                    "solved": frame.solvedJoints.contains(jointName),
                    "missing": frame.missingJoints.contains(jointName),
                    "projectionError": Double(frame.projectionErrors[jointName] ?? 0)
                ]
            }

            return [
                "frame": frame.frameIndex,
                "timeSeconds": frame.timeSeconds,
                "bodyBasis": [
                    "origin": vectorArray(frame.bodyBasis.origin),
                    "right": vectorArray(frame.bodyBasis.right),
                    "up": vectorArray(frame.bodyBasis.up),
                    "forward": vectorArray(frame.bodyBasis.forward)
                ],
                "joints": joints
            ]
        }

        let root: [String: Any] = [
            "schema": "com.gravitas.rotomotion.ray_solve_reference.v0",
            "rigID": solve.rigID,
            "rigVersion": solve.rigVersion,
            "sourceKind": solve.sourceKind,
            "targetHeightMeters": solve.targetHeightMeters,
            "sceneUnitsPerMeter": solve.sceneUnitsPerMeter,
            "armatureSceneScale": solve.armatureSceneScale,
            "frameCount": solve.frameCount,
            "frames": frames
        ]

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: url, options: .atomic)
    }

    private static func vectorArray(_ value: SIMD3<Float>) -> [Double] {
        [
            Double(value.x),
            Double(value.y),
            Double(value.z)
        ]
    }
}
