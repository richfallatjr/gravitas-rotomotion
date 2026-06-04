import Foundation

enum RigProfileLoader {
    static func loadRigProfile(from url: URL) throws -> RigProfile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(RigProfile.self, from: data)
    }

    static func loadBundledDefaultProfile() throws -> RigProfile {
        guard let url = Bundle.main.url(
            forResource: "GravitasMeshyBiped24_v001.rig_profile",
            withExtension: "json"
        ) else {
            throw NSError(
                domain: "GravitasRotoMotion",
                code: 4001,
                userInfo: [NSLocalizedDescriptionKey: "Default rig profile resource was not found."]
            )
        }

        return try loadRigProfile(from: url)
    }
}
