import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var roto = RotoMotionViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    VideoPoseViewport(
                        player: roto.player,
                        videoURL: roto.videoURL,
                        rawFrame: roto.currentRawFrame,
                        normalizedFrame: roto.currentNormalizedFrame,
                        smoothedFrame: roto.currentSmoothedFrame,
                        fitFrame: roto.currentFitFrame,
                        videoSize: roto.videoSize,
                        showRaw: roto.showRaw,
                        showSmoothed: roto.showSmoothed,
                        showSmoothingDelta: roto.showSmoothingDelta,
                        showFittedRig: roto.showFittedRig,
                        projectionSettings: roto.projectionSettings,
                        onTimeChange: roto.handlePlaybackTimeChange
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    RotoMotionTimelineView(
                        frameCount: roto.frameCount,
                        currentFrame: roto.currentRawFrame,
                        currentTimelineText: roto.currentTimelineText,
                        currentFrameIndex: $roto.currentFrameIndex
                    ) { index in
                        roto.setCurrentFrameIndex(index, seekPlayer: true)
                    }
                }
                .padding(16)

                Divider()

                sidebar
                    .frame(width: 380)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Gravitas RotoMotion")
                .font(.headline)

            Spacer()

            Button(action: roto.openVideo) {
                Label("Open Video", systemImage: "folder")
            }
            .keyboardShortcut("o")

            Button {
                Task {
                    await roto.runVisionExtraction()
                }
            } label: {
                Label("Run Vision Extraction", systemImage: "figure.walk")
            }
            .disabled(roto.videoURL == nil || roto.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                videoSection
                extractionSection
                normalizationSection
                smoothingSection
                rigSection
                fitSection
                exportSection
                statusSection
            }
            .padding(16)
        }
    }

    private var videoSection: some View {
        Section("Video") {
            VStack(alignment: .leading, spacing: 8) {
                metricRow("File", roto.videoURL?.lastPathComponent ?? "None")
                metricRow("Duration", roto.durationText)
                metricRow("Nominal FPS", roto.fpsText)
                metricRow("Size", roto.sizeText)
            }
        }
    }

    private var extractionSection: some View {
        Section("Extraction") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sample FPS")
                    Spacer()
                    TextField(
                        "Sample FPS",
                        value: $roto.sampleFPS,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 82)
                }

                Stepper(
                    roto.maxFrames == 0 ? "Max Frames: No cap" : "Max Frames: \(roto.maxFrames)",
                    value: $roto.maxFrames,
                    in: 0...100_000,
                    step: 24
                )

                Toggle("Raw Vision points", isOn: $roto.showRaw)

                Button(action: roto.saveRawJSON) {
                    Label("Save Raw JSON", systemImage: "doc.text")
                }
                .disabled(roto.rawCapture == nil || roto.isWorking)

                HStack {
                    metricRow("Frames", "\(roto.rawCapture?.frames.count ?? 0)")
                    metricRow("Detected", roto.detectedFrameText)
                }
            }
        }
    }

    private var normalizationSection: some View {
        Section("Normalization") {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: roto.normalize) {
                    Label("Normalize Meshy24", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(roto.rawCapture == nil || roto.isWorking)

                Button(action: roto.saveNormalizedJSON) {
                    Label("Save Normalized JSON", systemImage: "doc.text")
                }
                .disabled(roto.normalizedCapture == nil || roto.isWorking)

                metricRow("Rig", CanonicalRig.rigID)
                metricRow("Joints", "\(CanonicalRig.jointNames.count)")
            }
        }
    }

    private var smoothingSection: some View {
        Section("Smoothing") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable smoothing", isOn: $roto.smoothingSettings.globalEnabled)

                HStack {
                    Text("Strength")
                    Slider(value: $roto.smoothingSettings.strength, in: 0...0.98)
                    Text(String(format: "%.2f", roto.smoothingSettings.strength))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                Toggle("Interpolate missing points", isOn: $roto.smoothingSettings.missingInterpolationEnabled)
                Toggle("Confidence weighted", isOn: $roto.smoothingSettings.confidenceWeighted)
                Toggle("Smoothed overlay", isOn: $roto.showSmoothed)
                Toggle("Smoothing delta vectors", isOn: $roto.showSmoothingDelta)

                HStack {
                    Button(action: roto.smooth) {
                        Label("Run Smoothing", systemImage: "waveform.path.ecg")
                    }
                    .disabled(roto.normalizedCapture == nil || roto.isWorking)

                    Button(action: roto.saveSmoothedJSON) {
                        Label("Save", systemImage: "doc.text")
                    }
                    .disabled(roto.smoothedCapture == nil || roto.isWorking)
                }
            }
        }
    }

    private var rigSection: some View {
        Section("Rig") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(action: roto.importRigProfile) {
                        Label("Import Rig Profile", systemImage: "square.and.arrow.down")
                    }

                    Button(action: roto.loadDefaultRigProfile) {
                        Label("Default", systemImage: "person.crop.rectangle")
                    }
                }

                Button(action: roto.saveRigProfileJSON) {
                    Label("Save Rig Profile", systemImage: "doc.text")
                }
                .disabled(roto.rigProfile == nil || roto.isWorking)

                metricRow("Loaded", roto.rigProfile?.rigID ?? "None")
                metricRow("Version", roto.rigProfile?.rigVersion ?? "--")
                metricRow("Validation", rigValidationText)
            }
        }
    }

    private var fitSection: some View {
        Section("Fit") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use smoothed targets", isOn: $roto.fitSettings.useSmoothedTargets)
                Picker("Fit Mode", selection: $roto.fitSettings.fitMode) {
                    ForEach(RigFitMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Target")
                    Slider(value: $roto.fitSettings.targetWeight, in: 0...1)
                    Text(String(format: "%.2f", roto.fitSettings.targetWeight))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Text("Previous")
                    Slider(value: $roto.fitSettings.previousFrameWeight, in: 0...0.95)
                    Text(String(format: "%.2f", roto.fitSettings.previousFrameWeight))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                Toggle("Fitted rig overlay", isOn: $roto.showFittedRig)

                HStack {
                    Button(action: roto.runFit) {
                        Label("Run Fit", systemImage: "figure.arms.open")
                    }
                    .disabled(roto.normalizedCapture == nil || roto.rigProfile == nil || roto.isWorking)

                    Button(action: roto.saveFitJSON) {
                        Label("Save", systemImage: "doc.text")
                    }
                    .disabled(roto.fitResult == nil || roto.isWorking)
                }

                metricRow("Fit Score", roto.currentFitScoreText)
                metricRow("Avg Error", roto.averageFitErrorText)
            }
        }
    }

    private var exportSection: some View {
        Section("Export") {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: roto.chooseOutputDirectory) {
                    Label("Choose Output Directory", systemImage: "folder.badge.gearshape")
                }

                Text(roto.outputDirectoryURL?.path ?? "Defaults to selected video folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                Button(action: roto.exportJockAnim) {
                    Label("Export JockAnim", systemImage: "square.and.arrow.up")
                }
                .disabled(roto.fitResult == nil || roto.isWorking)
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            ExtractionProgressView(
                isExtracting: roto.isWorking,
                progressText: roto.status,
                logLines: roto.logLines
            )
        }
    }

    private var rigValidationText: String {
        guard let rigProfile = roto.rigProfile else {
            return "--"
        }

        let validation = rigProfile.validate()
        return validation.valid ? "Valid" : "Missing \(validation.missingRequiredJoints.count)"
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
}

#Preview {
    ContentView()
}
