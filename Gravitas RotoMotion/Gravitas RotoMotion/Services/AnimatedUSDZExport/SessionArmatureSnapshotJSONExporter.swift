import Foundation
import simd

enum SessionArmatureSnapshotJSONExporter {
    static func write(
        snapshot: SessionArmatureSnapshot,
        to url: URL
    ) throws {
        var joints: [String: [[String: Any]]] = [:]

        for jointName in CanonicalRig.jointNames {
            var keys: [[String: Any]] = []

            for frame in snapshot.frames {
                guard let transform = frame.joints[jointName] else {
                    continue
                }

                let translation = vectorArray(transform.localTranslation)
                let rotation = vectorArray(transform.localRotationEulerXYZ)
                let scale = vectorArray(transform.localScale)

                keys.append([
                    "frame": frame.frameIndex,
                    "time": frame.timeSeconds,
                    "localTranslationXYZ": translation,
                    "localRotationEulerXYZ": rotation,
                    "localScaleXYZ": scale,
                    "translation_xyz": translation,
                    "rotation_euler_xyz": rotation,
                    "scale_xyz": scale,
                    "curve": "linear"
                ])
            }

            if !keys.isEmpty {
                joints[jointName] = keys
            }
        }

        let root: [String: Any] = [
            "schema": snapshot.schema,
            "sourceKind": snapshot.sourceKind,
            "rigID": snapshot.rigID,
            "rigVersion": snapshot.rigVersion,
            "frameCount": snapshot.frameCount,
            "fps": snapshot.fps,
            "transform_space": "local_parent",
            "rotation_order": "euler_xyz_radians",
            "translation_policy": "all_local",
            "scale_policy": "all_local",
            "joints": joints
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
