import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var roto = RotoMotionViewModel()

    @State private var uiVideoURL: URL?
    @State private var uiDecodedFrames: [RotoVideoFrameCache.CachedFrame] = []
    @State private var uiCurrentImage: NSImage?
    @State private var uiCurrentFrameIndex = 0
    @State private var uiRenderToken = 0
    @State private var uiStatus = "Open a video to begin."
    @State private var uiIsPlaying = false
    @State private var uiLoop = true
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackStartHostTime: Date?
    @State private var playbackStartVideoTime = 0.0
    @State private var uiAudioPlayer: AVPlayer?
    @State private var uiAudioEndObserver: NSObjectProtocol?
    @State private var uiSecurityScopedURL: URL?
    @State private var uiSecurityScopedAccessActive = false
    @State private var uiSourceCharacterUSDZURL: URL?
    @State private var uiSourceCharacterSecurityScopedURL: URL?
    @State private var uiSourceCharacterSecurityScopedAccessActive = false
    @State private var uiAnimatedUSDZSourceURL: URL?
    @State private var uiAnimatedUSDZSourceSecurityScopedURL: URL?
    @State private var uiAnimatedUSDZSourceSecurityScopedAccessActive = false
    @State private var pipelineRenderToken = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            HStack(spacing: 12) {
                videoPanel
                    .frame(minWidth: 680)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                controlPanel
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            }
            .padding(12)

            Divider()

            statusBar
        }
        .frame(minWidth: 1120, minHeight: 820)
        .onAppear {
            print("[RotoMotion UI] Main ContentView appeared")
        }
        .onDisappear {
            releaseUIVideoAccess()
            releaseUISourceCharacterAccess()
            releaseUIAnimatedUSDZSourceAccess()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Open Video") {
                openVideoDirectlyInContentView()
            }
            .buttonStyle(.borderedProminent)

            Button(uiIsPlaying ? "Pause" : "Play") {
                toggleUIDirectPlayback()
            }
            .disabled(uiDecodedFrames.isEmpty)

            Button("Restart") {
                setUIDirectFrame(0)
                playUIDirect()
            }
            .disabled(uiDecodedFrames.isEmpty)

            Toggle("Loop", isOn: $uiLoop)

            Divider()
                .frame(height: 22)

            Button("Run Vision") {
                Task {
                    await roto.runVisionExtraction()
                    pipelineRenderToken += 1
                    uiStatus = roto.status
                }
            }
            .disabled(runVisionDisabledReason != nil)

            Button("Normalize Meshy24") {
                roto.normalize()
                pipelineRenderToken += 1
                uiStatus = roto.status
            }
            .disabled(normalizeDisabledReason != nil)

            Button("Save Raw Vision") {
                roto.saveRawJSON()
                uiStatus = roto.status
            }
            .disabled(roto.rawCapture == nil)

            Button("Save Normalized") {
                roto.saveNormalizedJSON()
                uiStatus = roto.status
            }
            .disabled(roto.normalizedCapture == nil)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.top, 42)
        .padding(.bottom, 10)
        .zIndex(10)
    }

    private var videoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RotoMotion Video")
                    .font(.headline)

                Spacer()

                Text("Frame \(uiCurrentFrameIndex) / \(max(uiDecodedFrames.count - 1, 0))")
                    .font(.caption)
                    .monospacedDigit()

                Text("t \(String(format: "%.3f", currentUIVideoTimeSeconds))s")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(uiStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            RotoSceneVideoViewport(
                image: uiCurrentImage,
                frameIndex: uiCurrentFrameIndex,
                rawFrame: currentRawFrame,
                normalizedFrame: currentNormalizedFrame,
                smoothedFrame: nil,
                groundPlane: roto.groundPlane,
                showRawVision: roto.showRawVisionPoints,
                showNormalizedMeshy: roto.showNormalizedMeshyPoints,
                showSmoothedMeshy: false,
                showGroundPlane: roto.groundPlane.visible
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            timelineControls
        }
    }

    private var timelineControls: some View {
        HStack {
            Button("◀︎") {
                pauseUIDirect()
                setUIDirectFrame(uiCurrentFrameIndex - 1)
            }
            .disabled(uiDecodedFrames.isEmpty)

            Slider(
                value: Binding(
                    get: {
                        Double(uiCurrentFrameIndex)
                    },
                    set: { value in
                        pauseUIDirect()
                        setUIDirectFrame(Int(value.rounded()))
                    }
                ),
                in: 0...Double(max(uiDecodedFrames.count - 1, 1)),
                step: 1
            )
            .disabled(uiDecodedFrames.isEmpty)

            Button("▶︎") {
                pauseUIDirect()
                setUIDirectFrame(uiCurrentFrameIndex + 1)
            }
            .disabled(uiDecodedFrames.isEmpty)
        }
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File: \(uiVideoURL?.lastPathComponent ?? "none")")
                        Text("Source frames: \(uiDecodedFrames.count)")
                        Text("Current image: \(uiCurrentImage == nil ? "nil" : "yes")")
                        Text("Current time: \(String(format: "%.3f", currentUIVideoTimeSeconds))s")
                        Text("Visual FPS: \(String(format: "%.3f", RotoVideoFrameCache.estimatedFPS(frames: uiDecodedFrames)))")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Vision Pipeline") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Raw Vision: \(roto.rawCapture?.frames.count ?? 0) frames")
                        Text("Normalized Meshy24: \(roto.normalizedCapture?.frames.count ?? 0) frames")

                        HStack {
                            Button("Save Raw") {
                                roto.saveRawJSON()
                                uiStatus = roto.status
                            }
                            .disabled(roto.rawCapture == nil)

                            Button("Save Normalized") {
                                roto.saveNormalizedJSON()
                                uiStatus = roto.status
                            }
                            .disabled(roto.normalizedCapture == nil)
                        }

                        if let reason = runVisionDisabledReason {
                            Text("Run Vision disabled: \(reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let reason = normalizeDisabledReason {
                            Text("Normalize disabled: \(reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Overlays") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Raw Vision Points", isOn: $roto.showRawVisionPoints)
                        Toggle("Normalized Meshy24 Skeleton", isOn: $roto.showNormalizedMeshyPoints)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                animatedUSDZExportPanel

                runtimePreviewPackagePanel

                diagnosticsPanel
            }
            .padding(10)
        }
    }

    private var runtimePreviewPackagePanel: some View {
        GroupBox("Runtime Preview Package") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Choose Source Character USDZ") {
                    chooseSourceCharacterUSDZDirectly()
                }

                Text((uiSourceCharacterUSDZURL ?? roto.sourceCharacterUSDZURL)?.lastPathComponent ?? "No character USDZ selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Clip ID", text: $roto.exportClipID)
                    .textFieldStyle(.roundedBorder)

                TextField("Display Name", text: $roto.exportDisplayName)
                    .textFieldStyle(.roundedBorder)

                Button("Export Jock Sidecar Package") {
                    if let uiSourceCharacterUSDZURL {
                        roto.sourceCharacterUSDZURL = uiSourceCharacterUSDZURL
                    }

                    roto.exportPreviewPackage()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(previewPackageReadinessText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.exportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var animatedUSDZExportPanel: some View {
        GroupBox("Animated USDZ Export") {
            VStack(alignment: .leading, spacing: 8) {
                Button("Check OpenUSD Tools") {
                    roto.checkOpenUSDTools()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(openUSDToolsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose Source USDZ") {
                    chooseAnimatedUSDZSourceDirectly()
                }

                Text((uiAnimatedUSDZSourceURL ?? roto.animatedUSDZSourceURL)?.lastPathComponent ?? "No source USDZ")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(animatedUSDZMemorySourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Clip ID", text: $roto.animatedUSDZClipID)
                    .textFieldStyle(.roundedBorder)

                Button("Export Animated USDZ") {
                    if let uiAnimatedUSDZSourceURL {
                        roto.animatedUSDZSourceURL = uiAnimatedUSDZSourceURL
                    }

                    roto.exportAnimatedUSDZ()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(animatedUSDZReadinessText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.animatedUSDZExportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var openUSDToolsText: String {
        guard let openUSDToolStatus = roto.openUSDToolStatus else {
            return "Tools not checked."
        }

        if openUSDToolStatus.ready {
            return "Tools ready. usdzip: \(openUSDToolStatus.usdzipPath ?? "found")"
        }

        return """
        Tools missing.
        Python OK: \(openUSDToolStatus.pythonOK)
        usdzip OK: \(openUSDToolStatus.usdzipOK)
        """
    }

    private var animatedUSDZReadinessText: String {
        var missing: [String] = []

        if uiAnimatedUSDZSourceURL == nil && roto.animatedUSDZSourceURL == nil {
            missing.append("source USDZ")
        }

        if roto.fitResult == nil && roto.normalizedCapture == nil && roto.smoothedCapture == nil {
            missing.append("normalized, smoothed, or fitted in-memory animation")
        }

        if missing.isEmpty {
            return "Ready to export from current in-memory animation."
        }

        return "Needs: \(missing.joined(separator: ", "))."
    }

    private var animatedUSDZMemorySourceText: String {
        if let fitResult = roto.fitResult {
            return "Animation source: current rig fit local rotations in memory (\(fitResult.frames.count) frames)."
        }

        if let smoothed = roto.smoothedCapture {
            return "Animation source: smoothed Meshy markers in memory (\(smoothed.frames.count) frames), solved against source bone lengths at 1.74 m."
        }

        if let normalized = roto.normalizedCapture {
            return "Animation source: normalized Meshy markers in memory (\(normalized.frames.count) frames), solved against source bone lengths at 1.74 m."
        }

        return "Animation source: none yet. Run Vision and Normalize first."
    }

    private var previewPackageReadinessText: String {
        var missing: [String] = []

        if uiSourceCharacterUSDZURL == nil && roto.sourceCharacterUSDZURL == nil {
            missing.append("source character USDZ")
        }

        if roto.normalizedCapture == nil && roto.smoothedCapture == nil {
            missing.append("normalized or smoothed animation")
        }

        if missing.isEmpty {
            return "Ready to export."
        }

        return "Needs: \(missing.joined(separator: ", "))."
    }

    private var diagnosticsPanel: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                Text(roto.status)
                    .font(.caption)
                    .lineLimit(2)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(roto.diagnostics.lines.suffix(18).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2)
                                .monospaced()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 140)

                Button("Clear Log") {
                    roto.diagnostics.clear()
                    pipelineRenderToken += 1
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
                .font(.caption)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var statusText: String {
        roto.status.isEmpty ? uiStatus : roto.status
    }

    private var uiVideoAspectRatio: CGFloat {
        guard let image = uiCurrentImage, image.size.height > 0 else {
            return 9.0 / 16.0
        }

        return image.size.width / image.size.height
    }

    private var runVisionDisabledReason: String? {
        if uiVideoURL == nil {
            return "No video selected."
        }

        if roto.isWorking {
            return "Pipeline operation is running."
        }

        return nil
    }

    private var normalizeDisabledReason: String? {
        guard let rawCapture = roto.rawCapture else {
            return "No raw Vision capture."
        }

        if rawCapture.frames.isEmpty {
            return "Raw Vision capture has zero frames."
        }

        if roto.isWorking {
            return "Pipeline operation is running."
        }

        return nil
    }

    private var currentUIVideoTimeSeconds: Double {
        guard uiDecodedFrames.indices.contains(uiCurrentFrameIndex) else {
            return 0.0
        }

        return uiDecodedFrames[uiCurrentFrameIndex].timeSeconds
    }

    private var currentRawFrame: RawVisionPoseCapture.PoseFrame? {
        nearestRawFrame(forTime: currentUIVideoTimeSeconds)
    }

    private var currentNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        nearestNormalizedFrame(forTime: currentUIVideoTimeSeconds)
    }

    private func nearestRawFrame(forTime time: Double) -> RawVisionPoseCapture.PoseFrame? {
        guard let frames = roto.rawCapture?.frames, !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func nearestNormalizedFrame(forTime time: Double) -> NormalizedMeshyPoseCapture.Frame? {
        guard let frames = roto.normalizedCapture?.frames, !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func chooseSourceCharacterUSDZDirectly() {
        print("[RotoMotion UI] Choose Source Character USDZ requested.")

        guard let url = FilePanelHelpers.openUSDZURL() else {
            roto.exportStatus = "Source USDZ selection canceled."
            roto.status = roto.exportStatus
            uiStatus = roto.exportStatus
            roto.diagnostics.log(roto.exportStatus)
            pipelineRenderToken += 1
            return
        }

        releaseUISourceCharacterAccess()

        let didAccess = url.startAccessingSecurityScopedResource()

        uiSourceCharacterUSDZURL = url
        uiSourceCharacterSecurityScopedURL = url
        uiSourceCharacterSecurityScopedAccessActive = didAccess

        roto.sourceCharacterUSDZURL = url
        roto.exportStatus = "Selected source character: \(url.lastPathComponent)"
        roto.status = roto.exportStatus
        uiStatus = roto.exportStatus
        pipelineRenderToken += 1

        roto.diagnostics.log("""
        Selected source character USDZ:
          path: \(url.path)
          securityScoped: \(didAccess)
          fileExists: \(FileManager.default.fileExists(atPath: url.path))
        """)

        print(
            """
            [RotoMotion UI] Selected Source Character USDZ
              path: \(url.path)
              securityScoped: \(didAccess)
              fileExists: \(FileManager.default.fileExists(atPath: url.path))
            """
        )
    }

    private func chooseAnimatedUSDZSourceDirectly() {
        print("[RotoMotion UI] Choose Animated USDZ Source requested.")

        guard let url = FilePanelHelpers.openUSDZURL() else {
            roto.animatedUSDZExportStatus = "Animated USDZ source selection canceled."
            roto.status = roto.animatedUSDZExportStatus
            uiStatus = roto.animatedUSDZExportStatus
            roto.diagnostics.log(roto.animatedUSDZExportStatus)
            pipelineRenderToken += 1
            return
        }

        releaseUIAnimatedUSDZSourceAccess()

        let didAccess = url.startAccessingSecurityScopedResource()

        uiAnimatedUSDZSourceURL = url
        uiAnimatedUSDZSourceSecurityScopedURL = url
        uiAnimatedUSDZSourceSecurityScopedAccessActive = didAccess

        roto.animatedUSDZSourceURL = url
        roto.animatedUSDZExportStatus = "Selected source USDZ: \(url.lastPathComponent)"
        roto.status = roto.animatedUSDZExportStatus
        uiStatus = roto.animatedUSDZExportStatus
        pipelineRenderToken += 1

        roto.diagnostics.log("""
        Selected animated USDZ source:
          path: \(url.path)
          securityScoped: \(didAccess)
          fileExists: \(FileManager.default.fileExists(atPath: url.path))
        """)
    }

    private func openVideoDirectlyInContentView() {
        print("[RotoMotion UI] Open Video requested.")

        guard let url = FilePanelHelpers.openVideoURL() else {
            uiStatus = "Open video canceled."
            roto.status = uiStatus
            roto.diagnostics.log("Open Video canceled by user.")
            return
        }

        releaseUIVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()
        uiSecurityScopedURL = url
        uiSecurityScopedAccessActive = didAccess
        uiVideoURL = url

        uiStatus = "Decoding \(url.lastPathComponent)..."
        uiDecodedFrames = []
        uiCurrentImage = nil
        uiCurrentFrameIndex = 0
        uiRenderToken += 1
        playbackStartHostTime = nil
        playbackStartVideoTime = 0
        pipelineRenderToken += 1

        roto.videoURL = url
        roto.lastLoadedVideoURL = url
        roto.outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        roto.decodedFrames = []
        roto.currentVideoFrameImage = nil
        roto.currentFrameIndex = 0
        roto.currentTimeSeconds = 0
        roto.maxFrameIndex = 0
        roto.rawCapture = nil
        roto.normalizedCapture = nil
        roto.smoothedCapture = nil
        roto.fitResult = nil
        roto.videoPlaybackStatus = "Decoding frames..."
        roto.status = "Loaded video: \(url.lastPathComponent)"
        roto.diagnostics.log("""
        Open Video selected:
          path: \(url.path)
          securityScoped: \(didAccess)
        """)

        installUIAudioPlayer(for: url)

        Task {
            let cache = RotoVideoFrameCache()

            await cache.loadSourceFrames(
                from: url,
                maxFrames: 0,
                maximumImageDimension: 1280
            )

            await MainActor.run {
                let frames = cache.frames
                uiDecodedFrames = frames
                uiCurrentFrameIndex = 0
                uiCurrentImage = frames.first?.image
                uiRenderToken += 1
                pipelineRenderToken += 1
                let fpsEstimate = RotoVideoFrameCache.estimatedFPS(frames: frames)
                uiStatus = frames.isEmpty ? cache.status : "Video source frames ready: \(frames.count)"

                roto.decodedFrames = frames
                roto.maxFrameIndex = max(0, frames.count - 1)
                roto.currentFrameIndex = 0
                roto.currentTimeSeconds = frames.first?.timeSeconds ?? 0
                roto.currentVideoFrameImage = frames.first?.image
                roto.imageRenderToken += 1
                roto.videoPlaybackStatus = uiStatus
                roto.status = "Video ready: \(frames.count) source frames"
                roto.diagnostics.log("""
                SOURCE frame decode assigned to active UI:
                  decodedFrames: \(frames.count)
                  estimatedFPS: \(String(format: "%.3f", fpsEstimate))
                  firstTime: \(frames.first?.timeSeconds ?? -1)
                  lastTime: \(frames.last?.timeSeconds ?? -1)
                  currentImage: \(uiCurrentImage != nil)
                  imageSize: \(String(describing: uiCurrentImage?.size))
                  Run Vision enabled: \(runVisionDisabledReason == nil)
                """)

                print(
                    """
                    [RotoMotion UI] Decode assigned to active video card
                      frames: \(frames.count)
                      estimatedFPS: \(String(format: "%.3f", fpsEstimate))
                      image exists: \(uiCurrentImage != nil)
                      image size: \(String(describing: uiCurrentImage?.size))
                    """
                )
            }
        }
    }

    private func installUIAudioPlayer(for url: URL) {
        if let uiAudioEndObserver {
            NotificationCenter.default.removeObserver(uiAudioEndObserver)
            self.uiAudioEndObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        uiAudioPlayer = player

        uiAudioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if uiLoop {
                    setUIDirectFrame(0, seekAudio: false)
                    playbackStartHostTime = Date()
                    playbackStartVideoTime = uiDecodedFrames.first?.timeSeconds ?? 0
                    uiAudioPlayer?.play()
                } else {
                    pauseUIDirect()
                    uiStatus = "Ended"
                    roto.videoPlaybackStatus = uiStatus
                }
            }
        }
    }

    private func setUIDirectFrame(
        _ index: Int,
        seekAudio: Bool = true
    ) {
        guard !uiDecodedFrames.isEmpty else {
            uiCurrentFrameIndex = 0
            uiCurrentImage = nil
            uiRenderToken += 1
            playbackStartVideoTime = 0
            roto.currentFrameIndex = 0
            roto.currentVideoFrameImage = nil
            roto.imageRenderToken += 1
            return
        }

        let clamped = max(0, min(uiDecodedFrames.count - 1, index))
        let frame = uiDecodedFrames[clamped]

        uiCurrentFrameIndex = clamped
        uiCurrentImage = frame.image
        uiRenderToken += 1

        roto.currentFrameIndex = clamped
        roto.currentTimeSeconds = frame.timeSeconds
        roto.currentVideoFrameImage = frame.image
        roto.imageRenderToken += 1

        if seekAudio {
            playbackStartVideoTime = frame.timeSeconds

            if uiIsPlaying {
                playbackStartHostTime = Date()
            }

            uiAudioPlayer?.seek(
                to: CMTime(seconds: frame.timeSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func toggleUIDirectPlayback() {
        if uiIsPlaying {
            pauseUIDirect()
        } else {
            playUIDirect()
        }
    }

    private func playUIDirect() {
        guard !uiDecodedFrames.isEmpty else {
            uiStatus = "Cannot play: no decoded frames."
            roto.videoPlaybackStatus = uiStatus
            roto.diagnostics.log("Cannot play video: decodedFrames is empty.")
            return
        }

        playbackTask?.cancel()
        playbackStartHostTime = Date()
        playbackStartVideoTime = uiDecodedFrames[min(uiCurrentFrameIndex, uiDecodedFrames.count - 1)].timeSeconds
        uiIsPlaying = true
        uiStatus = "Playing"
        roto.videoPlaybackStatus = uiStatus

        uiAudioPlayer?.seek(
            to: CMTime(seconds: playbackStartVideoTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        uiAudioPlayer?.play()

        roto.diagnostics.log("""
        Playback started:
          startFrame: \(uiCurrentFrameIndex)
          startVideoTime: \(playbackStartVideoTime)
          frameCount: \(uiDecodedFrames.count)
          firstTime: \(uiDecodedFrames.first?.timeSeconds ?? -1)
          lastTime: \(uiDecodedFrames.last?.timeSeconds ?? -1)
          loop: \(uiLoop)
        """)

        playbackTask = Task { @MainActor in
            while !Task.isCancelled {
                updatePlaybackFrameFromClock()
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
        }
    }

    private func pauseUIDirect() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackStartHostTime = nil
        uiIsPlaying = false
        uiAudioPlayer?.pause()
        uiStatus = "Paused"
        roto.videoPlaybackStatus = uiStatus
        roto.diagnostics.log("Playback paused at frame \(uiCurrentFrameIndex).")
    }

    private func updatePlaybackFrameFromClock() {
        guard uiIsPlaying,
              !uiDecodedFrames.isEmpty,
              let playbackStartHostTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(playbackStartHostTime)
        let wallClockTime = playbackStartVideoTime + elapsed
        let playerTime = uiAudioPlayer.map { CMTimeGetSeconds($0.currentTime()) }
        var targetTime = playerTime?.isFinite == true
            ? (playerTime ?? wallClockTime)
            : wallClockTime

        let firstTime = uiDecodedFrames.first?.timeSeconds ?? 0
        let lastTime = uiDecodedFrames.last?.timeSeconds ?? 0
        let duration = max(lastTime - firstTime, 0.001)

        if targetTime > lastTime {
            if uiLoop {
                let relative = targetTime - firstTime
                let looped = relative.truncatingRemainder(dividingBy: duration)
                targetTime = firstTime + looped
                self.playbackStartHostTime = Date()
                self.playbackStartVideoTime = targetTime
                uiAudioPlayer?.seek(
                    to: CMTime(seconds: targetTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                uiAudioPlayer?.play()
            } else {
                setUIDirectFrame(uiDecodedFrames.count - 1, seekAudio: false)
                pauseUIDirect()
                uiStatus = "Ended"
                roto.videoPlaybackStatus = uiStatus
                return
            }
        }

        let frameIndex = nearestUIFrameIndex(forTime: targetTime)

        if frameIndex != uiCurrentFrameIndex {
            setUIDirectFrame(frameIndex, seekAudio: false)
        }
    }

    private func nearestUIFrameIndex(forTime time: Double) -> Int {
        guard !uiDecodedFrames.isEmpty else {
            return 0
        }

        if time <= uiDecodedFrames[0].timeSeconds {
            return 0
        }

        if time >= uiDecodedFrames[uiDecodedFrames.count - 1].timeSeconds {
            return uiDecodedFrames.count - 1
        }

        var low = 0
        var high = uiDecodedFrames.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let midTime = uiDecodedFrames[mid].timeSeconds

            if midTime < time {
                low = mid + 1
            } else if midTime > time {
                high = mid - 1
            } else {
                return mid
            }
        }

        let upper = min(low, uiDecodedFrames.count - 1)
        let lower = max(upper - 1, 0)
        let lowerDistance = abs(uiDecodedFrames[lower].timeSeconds - time)
        let upperDistance = abs(uiDecodedFrames[upper].timeSeconds - time)

        return lowerDistance <= upperDistance ? lower : upper
    }

    private func stopUIDirectPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackStartHostTime = nil
        uiIsPlaying = false
    }

    private func releaseUIVideoAccess() {
        stopUIDirectPlayback()
        uiStatus = "Paused"

        if let uiAudioEndObserver {
            NotificationCenter.default.removeObserver(uiAudioEndObserver)
            self.uiAudioEndObserver = nil
        }

        uiAudioPlayer?.pause()
        uiAudioPlayer = nil

        if uiSecurityScopedAccessActive,
           let uiSecurityScopedURL {
            uiSecurityScopedURL.stopAccessingSecurityScopedResource()
        }

        uiSecurityScopedURL = nil
        uiSecurityScopedAccessActive = false
    }

    private func releaseUISourceCharacterAccess() {
        if uiSourceCharacterSecurityScopedAccessActive,
           let uiSourceCharacterSecurityScopedURL {
            uiSourceCharacterSecurityScopedURL.stopAccessingSecurityScopedResource()
        }

        uiSourceCharacterSecurityScopedURL = nil
        uiSourceCharacterSecurityScopedAccessActive = false
    }

    private func releaseUIAnimatedUSDZSourceAccess() {
        if uiAnimatedUSDZSourceSecurityScopedAccessActive,
           let uiAnimatedUSDZSourceSecurityScopedURL {
            uiAnimatedUSDZSourceSecurityScopedURL.stopAccessingSecurityScopedResource()
        }

        uiAnimatedUSDZSourceSecurityScopedURL = nil
        uiAnimatedUSDZSourceSecurityScopedAccessActive = false
    }

}
