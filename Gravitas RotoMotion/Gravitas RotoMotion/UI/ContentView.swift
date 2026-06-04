import AVFoundation
import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var exporter = RotoMotionExporter()

    @State private var videoURL: URL?
    @State private var outputDirectoryURL: URL?
    @State private var project: RotoMotionProject?
    @State private var player: AVPlayer?

    @State private var sampleFPS: Double = 24
    @State private var maxFrames: Int = 0
    @State private var normalizeCoordinates = true
    @State private var exportUSDZ = true

    @State private var currentFrameIndex = 0
    @State private var currentTimeSeconds = 0.0
    @State private var logLines: [String] = ["Ready."]

    private var currentFrame: RawVisionPoseCapture.PoseFrame? {
        guard
            let frames = exporter.capture?.frames,
            frames.indices.contains(currentFrameIndex)
        else {
            return nil
        }

        return frames[currentFrameIndex]
    }

    private var videoSize: CGSize {
        if let project {
            return project.metadata.naturalSize
        }

        if let source = exporter.capture?.sourceVideo {
            return CGSize(width: source.naturalWidth, height: source.naturalHeight)
        }

        return CGSize(width: 16, height: 9)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    VideoPoseViewport(
                        player: player,
                        videoURL: videoURL,
                        currentFrame: currentFrame,
                        videoSize: videoSize,
                        onTimeChange: handlePlaybackTimeChange
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    timeline
                }
                .padding(16)

                Divider()

                sidebar
                    .frame(width: 340)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Gravitas RotoMotion")
                .font(.headline)

            Spacer()

            Button(action: openVideo) {
                Label("Open Video", systemImage: "folder")
            }
            .keyboardShortcut("o")

            Button(action: runExtraction) {
                Label("Run Vision Extraction", systemImage: "figure.walk")
            }
            .disabled(videoURL == nil || exporter.isExtracting)

            Button(action: saveRawJSON) {
                Label("Save Raw JSON", systemImage: "doc.text")
            }
            .disabled(exporter.capture == nil || exporter.isExtracting)

            Button(action: exportOutputs) {
                Label(exportUSDZ ? "Export USDA + USDZ" : "Export USDA", systemImage: "square.and.arrow.up")
            }
            .disabled(exporter.capture == nil || exporter.isExtracting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Section("Video") {
                    VStack(alignment: .leading, spacing: 8) {
                        metricRow("File", videoURL?.lastPathComponent ?? "None")
                        metricRow("Duration", durationText)
                        metricRow("Nominal FPS", fpsText)
                        metricRow("Size", sizeText)
                    }
                }

                Section("Extraction") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sample FPS")
                            Spacer()
                            TextField("Sample FPS", value: $sampleFPS, format: .number.precision(.fractionLength(0...2)))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 82)
                        }

                        Stepper(
                            maxFrames == 0 ? "Max Frames: No cap" : "Max Frames: \(maxFrames)",
                            value: $maxFrames,
                            in: 0...100_000,
                            step: 24
                        )

                        Toggle("Normalize Coordinates", isOn: $normalizeCoordinates)
                            .disabled(true)

                        Toggle("Export USDZ", isOn: $exportUSDZ)
                    }
                }

                Section("Capture") {
                    VStack(alignment: .leading, spacing: 8) {
                        metricRow("Frames", "\(exporter.capture?.frames.count ?? 0)")
                        metricRow("Detected", detectedFrameText)
                        metricRow("Rig", CanonicalRig.rigID)
                        metricRow("Joints", "\(CanonicalRig.jointNames.count)")
                    }
                }

                Section("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: chooseOutputDirectory) {
                            Label("Choose Output Directory", systemImage: "folder.badge.gearshape")
                        }

                        Text(outputDirectoryURL?.path ?? "Defaults to selected video folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }

                Section("Status") {
                    ExtractionProgressView(
                        isExtracting: exporter.isExtracting,
                        progressText: exporter.progressText,
                        logLines: logLines
                    )
                }
            }
            .padding(16)
        }
    }

    private var timeline: some View {
        let frameCount = exporter.capture?.frames.count ?? 0
        let maxFrameIndex = max(frameCount - 1, 0)
        let sliderUpperBound = max(Double(maxFrameIndex), 1.0)
        let hasFrames = frameCount > 0

        return VStack(spacing: 8) {
            HStack {
                Text(currentTimelineText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if let currentFrame {
                    Text("Frame \(currentFrame.frameIndex) / \(maxFrameIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Slider(
                value: Binding(
                    get: {
                        Double(min(max(currentFrameIndex, 0), maxFrameIndex))
                    },
                    set: { newValue in
                        setCurrentFrameIndex(Int(newValue.rounded()), seekPlayer: true)
                    }
                ),
                in: 0...sliderUpperBound,
                step: 1
            )
            .disabled(!hasFrames)
        }
    }

    private var durationText: String {
        guard let duration = project?.metadata.durationSeconds, duration.isFinite else {
            return "--"
        }

        return "\(TimecodeFormatter.timecode(seconds: duration))"
    }

    private var fpsText: String {
        guard let fps = project?.metadata.nominalFrameRate, fps > 0 else {
            return "--"
        }

        return String(format: "%.2f", fps)
    }

    private var sizeText: String {
        guard let project else {
            return "--"
        }

        return "\(Int(project.metadata.naturalSize.width.rounded())) x \(Int(project.metadata.naturalSize.height.rounded()))"
    }

    private var detectedFrameText: String {
        guard let frames = exporter.capture?.frames else {
            return "0"
        }

        return "\(frames.filter(\.detected).count)"
    }

    private var currentTimelineText: String {
        if let currentFrame {
            return "\(currentFrame.timecode)  |  \(String(format: "%.3f", currentFrame.timeSeconds))s"
        }

        return "\(TimecodeFormatter.timecode(seconds: currentTimeSeconds))  |  \(String(format: "%.3f", currentTimeSeconds))s"
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func openVideo() {
        guard let url = FilePanelHelpers.openVideoURL() else { return }

        videoURL = url
        outputDirectoryURL = url.deletingLastPathComponent()
        exporter.capture = nil
        currentFrameIndex = 0
        currentTimeSeconds = 0

        let player = AVPlayer(url: url)
        self.player = player
        player.play()

        log("Opened \(url.lastPathComponent)")

        Task {
            do {
                project = try await RotoMotionProject.load(videoURL: url)
                log("Loaded video metadata.")
            } catch {
                log("Video metadata failed: \(error.localizedDescription)")
            }
        }
    }

    private func runExtraction() {
        guard let videoURL else {
            log("No video selected.")
            return
        }

        Task {
            do {
                let capture = try await exporter.runExtraction(
                    videoURL: videoURL,
                    sampleFPS: max(sampleFPS, 1.0),
                    maxFrames: maxFrames
                )

                setCurrentFrameIndex(0, seekPlayer: true)
                log("Vision extraction complete: \(capture.frames.count) frames.")
            } catch {
                log("Vision extraction failed: \(error.localizedDescription)")
            }
        }
    }

    private func saveRawJSON() {
        guard let capture = exporter.capture else {
            log(RotoMotionError.noCaptureAvailable.localizedDescription)
            return
        }

        guard let jsonURL = FilePanelHelpers.saveRawJSONURL(defaultDirectory: outputDirectoryURL) else {
            log(RotoMotionError.noOutputDirectory.localizedDescription)
            return
        }

        outputDirectoryURL = jsonURL.deletingLastPathComponent()

        do {
            try JSONCoding.writePretty(capture, to: jsonURL)
            log("Wrote \(jsonURL.lastPathComponent)")
        } catch {
            log("Raw JSON save failed: \(error.localizedDescription)")
        }
    }

    private func exportOutputs() {
        guard let capture = exporter.capture else {
            log(RotoMotionError.noCaptureAvailable.localizedDescription)
            return
        }

        guard let outputDir = resolvedOutputDirectory() else {
            log(RotoMotionError.noOutputDirectory.localizedDescription)
            return
        }

        let jsonURL = outputDir.appendingPathComponent("capture_raw_vision.json")
        let usdaURL = outputDir.appendingPathComponent("capture_pose_donor.usda")
        let usdzURL = outputDir.appendingPathComponent("capture_pose_donor.usdz")

        do {
            try JSONCoding.writePretty(capture, to: jsonURL)
            log("Wrote \(jsonURL.lastPathComponent)")

            try USDAPoseDonorWriter.writeUSDA(capture: capture, to: usdaURL)
            log("Wrote \(usdaURL.lastPathComponent)")

            if exportUSDZ {
                do {
                    try USDZPackager.packageUSDAAsUSDZ(usdaURL: usdaURL, usdzURL: usdzURL)
                    log("Wrote \(usdzURL.lastPathComponent)")
                } catch {
                    log("USDZ packaging failed; USDA remains available: \(error.localizedDescription)")
                }
            }
        } catch {
            log("Export failed: \(error.localizedDescription)")
        }
    }

    private func chooseOutputDirectory() {
        guard let url = FilePanelHelpers.chooseOutputDirectory() else { return }

        outputDirectoryURL = url
        log("Output directory set to \(url.path)")
    }

    private func resolvedOutputDirectory() -> URL? {
        if let outputDirectoryURL {
            return outputDirectoryURL
        }

        let selected = FilePanelHelpers.chooseOutputDirectory()
        outputDirectoryURL = selected
        return selected
    }

    private func handlePlaybackTimeChange(_ seconds: Double) {
        currentTimeSeconds = seconds

        guard let frames = exporter.capture?.frames, !frames.isEmpty else {
            return
        }

        let nearestIndex = frames.indices.min { lhs, rhs in
            abs(frames[lhs].timeSeconds - seconds) < abs(frames[rhs].timeSeconds - seconds)
        }

        if let nearestIndex, nearestIndex != currentFrameIndex {
            setCurrentFrameIndex(nearestIndex, seekPlayer: false)
        }
    }

    private func setCurrentFrameIndex(_ index: Int, seekPlayer: Bool) {
        let frameCount = exporter.capture?.frames.count ?? 0
        guard frameCount > 0 else {
            currentFrameIndex = 0
            return
        }

        let clamped = min(max(index, 0), frameCount - 1)
        currentFrameIndex = clamped

        guard seekPlayer, let frame = exporter.capture?.frames[clamped] else {
            return
        }

        player?.seek(
            to: CMTime(seconds: frame.timeSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func log(_ message: String) {
        logLines.append(message)

        if logLines.count > 80 {
            logLines.removeFirst(logLines.count - 80)
        }
    }
}

#Preview {
    ContentView()
}
