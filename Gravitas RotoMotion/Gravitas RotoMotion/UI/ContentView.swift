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
                        showRawVisionPoints: roto.showRawVisionPoints,
                        showNormalizedMeshyPoints: roto.showNormalizedMeshyPoints,
                        showSmoothedMeshyPoints: roto.showSmoothedMeshyPoints,
                        showSmoothingDeltaVectors: roto.showSmoothingDeltaVectors,
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

                rigScenePanel
                    .frame(width: 420)

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

                Toggle("Show Raw Vision Points", isOn: $roto.showRawVisionPoints)

                Button(action: roto.saveRawJSON) {
                    Label("Save Raw JSON", systemImage: "doc.text")
                }
                .disabled(roto.rawCapture == nil || roto.isWorking)

                HStack {
                    metricRow("Frames", "\(roto.rawCapture?.frames.count ?? 0)")
                    metricRow("Detected", roto.detectedFrameText)
                }

                metricRow("Raw Vision", "Variable joints")
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

                Toggle("Show Normalized Meshy24 Points", isOn: $roto.showNormalizedMeshyPoints)

                metricRow("Rig", CanonicalRig.rigID)
                metricRow("Meshy24", "\(CanonicalRig.jointNames.count) canonical joints")
            }
        }
    }

    private var smoothingSection: some View {
        Section("Smoothing") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Use Smoothing", isOn: $roto.smoothingPreviewEnabled)
                    .onChange(of: roto.smoothingPreviewEnabled) {
                        roto.recomputeSmoothingIfAvailable()
                    }

                HStack {
                    Text("Strength")
                    Slider(value: $roto.smoothingStrength, in: 0...1)
                        .onChange(of: roto.smoothingStrength) {
                            roto.recomputeSmoothingIfAvailable()
                        }
                    Text(String(format: "%.2f", roto.smoothingStrength))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                Stepper(
                    "Window Radius: \(roto.smoothingWindowRadius)",
                    value: $roto.smoothingWindowRadius,
                    in: 1...12
                )
                .onChange(of: roto.smoothingWindowRadius) {
                    roto.recomputeSmoothingIfAvailable()
                }

                Toggle("Interpolate missing points", isOn: $roto.smoothingSettings.missingInterpolationEnabled)
                    .onChange(of: roto.smoothingSettings.missingInterpolationEnabled) {
                        roto.recomputeSmoothingIfAvailable()
                    }
                Toggle("Confidence weighted", isOn: $roto.smoothingSettings.confidenceWeighted)
                    .onChange(of: roto.smoothingSettings.confidenceWeighted) {
                        roto.recomputeSmoothingIfAvailable()
                    }
                Toggle("Show Smoothed Meshy24 Points", isOn: $roto.showSmoothedMeshyPoints)
                Toggle("Show Smoothing Delta Vectors", isOn: $roto.showSmoothingDeltaVectors)

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

                Button("Toggle Raw / Smoothed") {
                    roto.showRawVisionPoints.toggle()
                    roto.showSmoothedMeshyPoints.toggle()
                }
            }
        }
    }

    private var rigSection: some View {
        Section("Rig / Model") {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: roto.importUSDZRig) {
                    Label("Load USDZ / USD Rig", systemImage: "cube.transparent")
                }

                Toggle("Show Imported Rig Model", isOn: $roto.showImportedRigModel)
                Toggle("Show Imported Rig Skeleton", isOn: $roto.showImportedRigSkeleton)

                Text(roto.rigImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)

                metricRow("Imported matched", "\(roto.importedRigScene?.skeletonJointNames.count ?? 0)")
                metricRow("Missing required", importedMissingRequiredText)
                metricRow("Model opacity", "\(Int(roto.rigOpacity * 100))%")

                Divider()

                Text("Measured Profile")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(action: roto.importRigProfile) {
                        Label("Import JSON Profile", systemImage: "square.and.arrow.down")
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

    private var rigScenePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imported Rig / Model")
                    .font(.headline)

                Spacer()

                Text("\(Int(roto.rigOpacity * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            RigSceneKitView(
                importedRigScene: roto.importedRigScene,
                opacity: CGFloat(roto.rigOpacity),
                showModel: roto.showImportedRigModel,
                showSkeleton: roto.showImportedRigSkeleton
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }

            Slider(value: $roto.rigOpacity, in: 0.05...1.0) {
                Text("Rig Opacity")
            }
            .onChange(of: roto.rigOpacity) {
                roto.updateImportedRigOpacity()
            }

            HStack {
                Button(action: roto.importUSDZRig) {
                    Label("Load USDZ / USD", systemImage: "cube.transparent")
                }

                Toggle("Model", isOn: $roto.showImportedRigModel)
                Toggle("Skeleton", isOn: $roto.showImportedRigSkeleton)
            }

            Text(roto.rigImportStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(16)
    }

    private var rigValidationText: String {
        guard let rigProfile = roto.rigProfile else {
            return "--"
        }

        let validation = rigProfile.validate()
        return validation.valid ? "Valid" : "Missing \(validation.missingRequiredJoints.count)"
    }

    private var importedMissingRequiredText: String {
        guard let validation = roto.importedRigScene?.validation else {
            return "--"
        }

        if validation.missingRequiredJoints.isEmpty {
            return "None"
        }

        return validation.missingRequiredJoints.joined(separator: ", ")
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
