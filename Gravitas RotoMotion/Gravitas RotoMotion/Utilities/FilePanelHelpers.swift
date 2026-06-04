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

    static func openRigAssetURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            "usdz",
            "usdc",
            "usd",
            "usda"
        ].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openJSONURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveRawJSONURL(defaultDirectory: URL?) -> URL? {
        saveJSONURL(
            defaultDirectory: defaultDirectory,
            defaultFileName: "capture_raw_vision.json"
        )
    }

    static func saveJSONURL(
        defaultDirectory: URL?,
        defaultFileName: String
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName
        panel.directoryURL = defaultDirectory

        return panel.runModal() == .OK ? panel.url : nil
    }
}
