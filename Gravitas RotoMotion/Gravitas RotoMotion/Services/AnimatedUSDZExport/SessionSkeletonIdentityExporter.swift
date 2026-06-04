import Foundation

enum SessionSkeletonIdentityExporter {
    static func write(
        skeletonPath: String?,
        jointPaths: [String],
        jointLeafNames: [String],
        to url: URL
    ) throws {
        let payload: [String: Any] = [
            "schema": "com.gravitas.rotomotion.session_skeleton_identity.v0",
            "skeletonPath": skeletonPath ?? NSNull(),
            "jointPaths": jointPaths,
            "jointLeafNames": jointLeafNames
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: url, options: .atomic)
    }
}
