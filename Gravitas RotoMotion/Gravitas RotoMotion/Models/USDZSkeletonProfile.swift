import Foundation

struct USDZSkeletonProfile: Codable, Equatable {
    let sourcePath: String
    let rootLayerPathInsideUSDZ: String?
    let skeletonPath: String
    let skelRootPath: String?
    let jointPaths: [String]
    let jointLeafNames: [String]
    let canonicalMatchedJoints: [String]
    let missingCanonicalJoints: [String]
    let estimatedHeightMeters: Double?
    let boneLengths: [String: Double]
    let unitScaleToMeters: Double?

    var validForMeshy24: Bool {
        missingCanonicalJoints.isEmpty
    }
}
