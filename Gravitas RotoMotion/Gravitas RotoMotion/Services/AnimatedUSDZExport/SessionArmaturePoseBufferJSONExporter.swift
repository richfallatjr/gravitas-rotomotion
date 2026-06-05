import Foundation

enum SessionArmaturePoseBufferJSONExporter {
    static func write(
        buffer: SessionArmaturePoseBuffer,
        to url: URL
    ) throws {
        var joints: [String: [[String: Any]]] = [:]

        for jointName in CanonicalRig.jointNames {
            let keys = buffer.frames.compactMap { frame -> [String: Any]? in
                guard let transform = frame.joints[jointName] else {
                    return nil
                }

                return [
                    "frame": frame.frameIndex,
                    "time": frame.timeSeconds,
                    "localTranslationXYZ": transform.localTranslationXYZ,
                    "localRotationWXYZ": transform.localRotationWXYZ,
                    "localScaleXYZ": transform.localScaleXYZ,
                    "translation_xyz": transform.localTranslationXYZ,
                    "rotation_wxyz": transform.localRotationWXYZ,
                    "scale_xyz": transform.localScaleXYZ,
                    "curve": "linear"
                ]
            }

            if !keys.isEmpty {
                joints[jointName] = keys
            }
        }

        let root: [String: Any] = [
            "schema": buffer.schema,
            "clipID": buffer.clipID,
            "frameCount": buffer.frames.count,
            "fps": buffer.fps,
            "sourceKind": "posed_armature_local_transforms",
            "transform_space": "local_parent",
            "rotation_order": "wxyz",
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
}
