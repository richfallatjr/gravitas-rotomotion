import Foundation

enum TimecodeFormatter {
    static func timecode(seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00.000" }

        let totalMilliseconds = Int((seconds * 1000.0).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let wholeSeconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000

        return String(
            format: "%02d:%02d:%02d.%03d",
            hours,
            minutes,
            wholeSeconds,
            milliseconds
        )
    }
}
