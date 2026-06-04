import AppKit
import UniformTypeIdentifiers

enum FilePanelHelpers {
    static func openVideoURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .movie,
            .mpeg4Movie,
            .quickTimeMovie
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveRawJSONURL(defaultDirectory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "capture_raw_vision.json"
        panel.directoryURL = defaultDirectory

        return panel.runModal() == .OK ? panel.url : nil
    }
}
