import Foundation

enum JSONCoding {
    static func writePretty<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]

        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
