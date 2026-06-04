import Combine
import Foundation

final class RotoMotionDiagnostics: ObservableObject {
    @Published private(set) var lines: [String] = []

    func log(
        _ message: String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = Self.timestamp()
        let entry = "[\(timestamp)] \(message)"

        lines.append(entry)

        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }

        print("[RotoMotion Diagnostics] \(entry)")
    }

    func clear() {
        lines.removeAll()
        print("[RotoMotion Diagnostics] cleared")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
