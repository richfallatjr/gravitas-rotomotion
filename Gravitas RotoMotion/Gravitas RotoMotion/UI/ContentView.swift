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
    @State private var playbackTimer: Timer?
    @State private var uiAudioPlayer: AVPlayer?
    @State private var uiAudioEndObserver: NSObjectProtocol?
    @State private var uiSecurityScopedURL: URL?
    @State private var uiSecurityScopedAccessActive = false
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

                Text(uiStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            RotoMotionVideoCard(
                image: uiCurrentImage,
                frameIndex: uiCurrentFrameIndex,
                rawFrame: currentRawFrame,
                normalizedFrame: currentNormalizedFrame,
                smoothedFrame: nil,
                showRawVisionPoints: roto.showRawVisionPoints,
                showNormalizedMeshyPoints: roto.showNormalizedMeshyPoints,
                showSmoothedMeshyPoints: false,
                showSmoothingDeltaVectors: false
            )
            .aspectRatio(uiVideoAspectRatio, contentMode: .fit)
            .frame(minWidth: 620, minHeight: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            timelineControls
        }
    }

    private var timelineControls: some View {
        HStack {
            Button("◀︎") {
                setUIDirectFrame(uiCurrentFrameIndex - 1)
            }
            .disabled(uiDecodedFrames.isEmpty)

            Slider(
                value: Binding(
                    get: {
                        Double(uiCurrentFrameIndex)
                    },
                    set: { value in
                        setUIDirectFrame(Int(value.rounded()))
                    }
                ),
                in: 0...Double(max(uiDecodedFrames.count - 1, 1)),
                step: 1
            )
            .disabled(uiDecodedFrames.isEmpty)

            Button("▶︎") {
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
                        Text("Decoded frames: \(uiDecodedFrames.count)")
                        Text("Current image: \(uiCurrentImage == nil ? "nil" : "yes")")
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

                diagnosticsPanel
            }
            .padding(10)
        }
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

    private var currentRawFrame: RawVisionPoseCapture.PoseFrame? {
        guard let frames = roto.rawCapture?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == uiCurrentFrameIndex }
            ?? (frames.indices.contains(uiCurrentFrameIndex) ? frames[uiCurrentFrameIndex] : nil)
    }

    private var currentNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        guard let frames = roto.normalizedCapture?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == uiCurrentFrameIndex }
            ?? (frames.indices.contains(uiCurrentFrameIndex) ? frames[uiCurrentFrameIndex] : nil)
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

            await cache.loadFrames(
                from: url,
                sampleFPS: 24.0,
                maxFrames: 0
            )

            await MainActor.run {
                let frames = cache.frames
                uiDecodedFrames = frames
                uiCurrentFrameIndex = 0
                uiCurrentImage = frames.first?.image
                uiRenderToken += 1
                pipelineRenderToken += 1
                uiStatus = frames.isEmpty ? cache.status : "Video frames ready: \(frames.count)"

                roto.decodedFrames = frames
                roto.maxFrameIndex = max(0, frames.count - 1)
                roto.currentFrameIndex = 0
                roto.currentTimeSeconds = frames.first?.timeSeconds ?? 0
                roto.currentVideoFrameImage = frames.first?.image
                roto.imageRenderToken += 1
                roto.videoPlaybackStatus = uiStatus
                roto.status = "Video ready: \(frames.count) frames"
                roto.diagnostics.log("""
                Frame decode assigned to active UI:
                  decodedFrames: \(frames.count)
                  currentImage: \(uiCurrentImage != nil)
                  imageSize: \(String(describing: uiCurrentImage?.size))
                  Run Vision enabled: \(runVisionDisabledReason == nil)
                """)

                print(
                    """
                    [RotoMotion UI] Decode assigned to active video card
                      frames: \(frames.count)
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
                    setUIDirectFrame(0)
                    uiAudioPlayer?.play()
                } else {
                    pauseUIDirect()
                    uiStatus = "Ended"
                    roto.videoPlaybackStatus = uiStatus
                }
            }
        }
    }

    private func setUIDirectFrame(_ index: Int) {
        guard !uiDecodedFrames.isEmpty else {
            uiCurrentFrameIndex = 0
            uiCurrentImage = nil
            uiRenderToken += 1
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

        uiAudioPlayer?.seek(
            to: CMTime(seconds: frame.timeSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func toggleUIDirectPlayback() {
        if uiIsPlaying {
            pauseUIDirect()
        } else {
            playUIDirect()
        }
    }

    private func playUIDirect() {
        guard !uiDecodedFrames.isEmpty else { return }

        playbackTimer?.invalidate()
        uiIsPlaying = true
        uiStatus = "Playing"
        roto.videoPlaybackStatus = uiStatus

        let frame = uiDecodedFrames[min(uiCurrentFrameIndex, uiDecodedFrames.count - 1)]
        uiAudioPlayer?.seek(
            to: CMTime(seconds: frame.timeSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        uiAudioPlayer?.play()

        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 24.0,
            repeats: true
        ) { _ in
            Task { @MainActor in
                advanceUIDirectPlayback()
            }
        }
    }

    private func pauseUIDirect() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        uiIsPlaying = false
        uiAudioPlayer?.pause()
        uiStatus = "Paused"
        roto.videoPlaybackStatus = uiStatus
    }

    private func advanceUIDirectPlayback() {
        guard !uiDecodedFrames.isEmpty else {
            pauseUIDirect()
            return
        }

        let next = uiCurrentFrameIndex + 1

        if next < uiDecodedFrames.count {
            setUIDirectFrame(next)
        } else if uiLoop {
            setUIDirectFrame(0)
            uiAudioPlayer?.play()
        } else {
            pauseUIDirect()
            uiStatus = "Ended"
            roto.videoPlaybackStatus = uiStatus
        }
    }

    private func releaseUIVideoAccess() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        uiIsPlaying = false

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
}
