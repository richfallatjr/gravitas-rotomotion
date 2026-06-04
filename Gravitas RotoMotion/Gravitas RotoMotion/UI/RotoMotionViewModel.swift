import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class RotoMotionViewModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @Published var videoURL: URL?
    @Published var outputDirectoryURL: URL?
    @Published var project: RotoMotionProject?
    @Published var decodedFrames: [RotoVideoFrameCache.CachedFrame] = []
    @Published var currentVideoFrameImage: NSImage?
    @Published var imageRenderToken = 0
    @Published var isFramePlaybackRunning = false
    @Published var framePlaybackFPS = 24.0
    @Published var isVideoLooping = true
    @Published var videoPlaybackStatus = "No video loaded."

    @Published var rawCapture: RawVisionPoseCapture?
    @Published var normalizedCapture: NormalizedMeshyPoseCapture?
    @Published var smoothedCapture: SmoothedMeshyPoseCapture?
    @Published var rigProfile: RigProfile?
    @Published var importedRigScene: ImportedRigScene?
    @Published var fitResult: RigFitResult?

    @Published var currentFrameIndex = 0
    @Published var currentTimeSeconds = 0.0
    @Published var maxFrameIndex = 0

    @Published var sampleFPS = 24.0
    @Published var maxFrames = 0

    @Published var showRawVisionPoints = true
    @Published var showNormalizedMeshyPoints = true
    @Published var showSmoothedMeshyPoints = true
    @Published var showSmoothingDeltaVectors = true
    @Published var showImportedRigModel = true
    @Published var showImportedRigSkeleton = true
    @Published var showFittedRig = true
    @Published var rigOverlayScale = 1.0
    @Published var rigOverlayOffsetX = 0.0
    @Published var rigOverlayOffsetY = 0.0

    @Published var groundPlane = GroundPlaneController.default

    @Published var smoothingPreviewEnabled = true
    @Published var smoothingStrength = 0.85
    @Published var smoothingWindowRadius = 4
    @Published var smoothingSettings = SmoothedMeshyPoseCapture.SmoothingSettings.default
    @Published var fitSettings = RigFitSettings.default
    @Published var projectionSettings = RigProjectionSettings.default

    @Published var rigOpacity = 0.5
    @Published var rigImportStatus = "No USDZ rig loaded."

    @Published var status = "Open a video to begin."
    @Published var logLines: [String] = ["Ready."]
    @Published var isWorking = false
    @Published var diagnostics = RotoMotionDiagnostics()

    @Published var lastLoadedVideoURL: URL?
    @Published var lastVisionError: String?
    @Published var lastNormalizeError: String?
    @Published var lastSmoothingError: String?
    @Published var lastRigError: String?

    private let exporter = RotoMotionExporter()
    private var videoSecurityScopedURL: URL?
    private var videoSecurityScopedAccessActive = false
    private var playbackTimer: Timer?
    private var audioPlayer: AVPlayer?
    private var audioEndObserver: NSObjectProtocol?

    deinit {
        playbackTimer?.invalidate()

        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
        }

        if videoSecurityScopedAccessActive,
           let videoSecurityScopedURL {
            videoSecurityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    var frameCount: Int {
        [
            decodedFrames.count,
            rawCapture?.frames.count,
            normalizedCapture?.frames.count,
            smoothedCapture?.frames.count,
            fitResult?.frames.count
        ]
        .compactMap { $0 }
        .max() ?? 0
    }

    var hasVideoURL: Bool {
        videoURL != nil
    }

    var hasDecodedFrames: Bool {
        !decodedFrames.isEmpty
    }

    var hasCurrentImage: Bool {
        currentVideoFrameImage != nil
    }

    var hasRawVision: Bool {
        rawCapture != nil && !(rawCapture?.frames.isEmpty ?? true)
    }

    var hasNormalizedMeshy24: Bool {
        normalizedCapture != nil && !(normalizedCapture?.frames.isEmpty ?? true)
    }

    var hasSmoothedMeshy24: Bool {
        smoothedCapture != nil && !(smoothedCapture?.frames.isEmpty ?? true)
    }

    var hasRigGeometry: Bool {
        (importedRigScene?.geometryNodeCount ?? 0) > 0
    }

    var hasMatchedRigJoints: Bool {
        !(importedRigScene?.skeletonJointNames.isEmpty ?? true)
    }

    var runVisionDisabledReason: String? {
        if videoURL == nil { return "No video URL selected." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var normalizeDisabledReason: String? {
        if rawCapture == nil { return "No raw Vision capture." }
        if rawCapture?.frames.isEmpty == true { return "Raw Vision capture has 0 frames." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var smoothingDisabledReason: String? {
        if normalizedCapture == nil { return "No normalized Meshy24 capture." }
        if normalizedCapture?.frames.isEmpty == true { return "Normalized Meshy24 has 0 frames." }
        if isWorking { return "Pipeline operation is running." }
        return nil
    }

    var exportDisabledReason: String? {
        if smoothedCapture == nil && normalizedCapture == nil {
            return "No normalized or smoothed capture."
        }
        return nil
    }

    var currentRawFrame: RawVisionPoseCapture.PoseFrame? {
        guard let frames = rawCapture?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == currentFrameIndex }
            ?? (frames.indices.contains(currentFrameIndex) ? frames[currentFrameIndex] : nil)
    }

    var currentNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        guard let frames = normalizedCapture?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == currentFrameIndex }
            ?? (frames.indices.contains(currentFrameIndex) ? frames[currentFrameIndex] : nil)
    }

    var currentSmoothedFrame: SmoothedMeshyPoseCapture.Frame? {
        guard let frames = smoothedCapture?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == currentFrameIndex }
            ?? (frames.indices.contains(currentFrameIndex) ? frames[currentFrameIndex] : nil)
    }

    var currentFitFrame: RigFitResult.FrameFit? {
        guard let frames = fitResult?.frames else {
            return nil
        }

        return frames.first { $0.frameIndex == currentFrameIndex }
            ?? (frames.indices.contains(currentFrameIndex) ? frames[currentFrameIndex] : nil)
    }

    var videoSize: CGSize {
        if let project {
            return project.metadata.naturalSize
        }

        if let source = rawCapture?.sourceVideo {
            return CGSize(width: source.naturalWidth, height: source.naturalHeight)
        }

        return CGSize(width: 16, height: 9)
    }

    var durationText: String {
        guard let duration = project?.metadata.durationSeconds, duration.isFinite else {
            return "--"
        }

        return TimecodeFormatter.timecode(seconds: duration)
    }

    var fpsText: String {
        guard let fps = project?.metadata.nominalFrameRate, fps > 0 else {
            return "--"
        }

        return String(format: "%.2f", fps)
    }

    var sizeText: String {
        guard let project else {
            return "--"
        }

        return "\(Int(project.metadata.naturalSize.width.rounded())) x \(Int(project.metadata.naturalSize.height.rounded()))"
    }

    var detectedFrameText: String {
        guard let frames = rawCapture?.frames else {
            return "0"
        }

        return "\(frames.filter(\.detected).count)"
    }

    var currentTimelineText: String {
        if let frame = currentRawFrame {
            return "\(frame.timecode)  |  \(String(format: "%.3f", frame.timeSeconds))s"
        }

        if !decodedFrames.isEmpty {
            let frameIndex = min(max(currentFrameIndex, 0), decodedFrames.count - 1)
            let seconds = decodedFrames[frameIndex].timeSeconds
            return "\(TimecodeFormatter.timecode(seconds: seconds))  |  \(String(format: "%.3f", seconds))s"
        }

        return "\(TimecodeFormatter.timecode(seconds: currentTimeSeconds))  |  \(String(format: "%.3f", currentTimeSeconds))s"
    }

    var currentFitScoreText: String {
        guard let score = currentFitFrame?.fitScore else {
            return "--"
        }

        return String(format: "%.3f", score)
    }

    var averageFitErrorText: String {
        guard let frame = currentFitFrame, !frame.fitErrors.isEmpty else {
            return "--"
        }

        let average = frame.fitErrors.values.reduce(0, +) / Double(frame.fitErrors.count)
        return String(format: "%.4f", average)
    }

    func openVideo() {
        diagnostics.log("Open Video requested.")

        guard let url = FilePanelHelpers.openVideoURL() else {
            diagnostics.log("Open Video canceled by user.")
            status = "Open video canceled."
            return
        }

        diagnostics.log("Selected video: \(url.path)")

        stopFramePlayback()
        releaseCurrentVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()

        videoSecurityScopedURL = url
        videoSecurityScopedAccessActive = didAccess

        videoURL = url
        lastLoadedVideoURL = url
        outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        rawCapture = nil
        normalizedCapture = nil
        smoothedCapture = nil
        fitResult = nil
        project = nil
        lastVisionError = nil
        lastNormalizeError = nil
        lastSmoothingError = nil
        decodedFrames = []
        currentVideoFrameImage = nil
        currentFrameIndex = 0
        currentTimeSeconds = 0
        maxFrameIndex = 0
        videoPlaybackStatus = "Decoding frames..."
        status = "Loaded video: \(url.lastPathComponent)"
        log("Opened \(url.lastPathComponent)")

        diagnostics.log("""
        Video state after selection:
          videoURL set: \(videoURL != nil)
          securityScoped: \(didAccess)
          decodedFrames cleared: \(decodedFrames.count)
          rawCapture cleared: \(rawCapture == nil)
          normalized cleared: \(normalizedCapture == nil)
          smoothed cleared: \(smoothedCapture == nil)
        """)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        audioPlayer = player
        installAudioEndObserver(for: item)

        print(
            """
            [RotoMotion Video] Opened video for frame-image playback
              url: \(url.path)
              securityScoped: \(didAccess)
            """
        )

        Task { @MainActor in
            let cache = RotoVideoFrameCache()
            diagnostics.log("Starting frame decode for \(url.lastPathComponent).")

            await cache.loadFrames(
                from: url,
                sampleFPS: framePlaybackFPS,
                maxFrames: 0
            )

            let frames = cache.frames

            decodedFrames = frames
            maxFrameIndex = max(0, frames.count - 1)
            currentFrameIndex = 0
            currentTimeSeconds = frames.first?.timeSeconds ?? 0
            currentVideoFrameImage = frames.first?.image
            imageRenderToken += 1
            videoPlaybackStatus = frames.isEmpty
                ? cache.status
                : "Video frames ready: \(frames.count)"
            status = "Video ready: \(frames.count) frames"

            diagnostics.log("""
            Frame decode completed and assigned to UI:
              decodedFrames: \(decodedFrames.count)
              maxFrameIndex: \(maxFrameIndex)
              currentFrameIndex: \(currentFrameIndex)
              currentVideoFrameImage exists: \(currentVideoFrameImage != nil)
              imageRenderToken: \(imageRenderToken)
              imageSize: \(String(describing: currentVideoFrameImage?.size))
              Run Vision enabled: \(runVisionDisabledReason == nil)
              Run Vision disabled reason: \(runVisionDisabledReason ?? "none")
            """)

            if !decodedFrames.isEmpty && currentVideoFrameImage == nil {
                diagnostics.log("ERROR: decodedFrames non-empty but currentVideoFrameImage nil.")
            }

            do {
                project = try await RotoMotionProject.load(videoURL: url)
                log("Loaded video metadata.")
            } catch {
                log("Video metadata failed: \(error.localizedDescription)")
            }
        }
    }

    func playVideo() {
        guard !decodedFrames.isEmpty else { return }

        stopFramePlayback()

        let currentTime = decodedFrames[min(currentFrameIndex, decodedFrames.count - 1)].timeSeconds
        audioPlayer?.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        audioPlayer?.play()

        isFramePlaybackRunning = true
        videoPlaybackStatus = "Playing"

        let interval = 1.0 / max(framePlaybackFPS, 1.0)
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceFramePlayback()
            }
        }
    }

    func pauseVideo() {
        stopFramePlayback()
        audioPlayer?.pause()
        videoPlaybackStatus = "Paused"
    }

    func restartVideo() {
        setCurrentFrameIndex(0)
        playVideo()
    }

    func togglePlayPause() {
        if isFramePlaybackRunning {
            pauseVideo()
        } else {
            playVideo()
        }
    }

    private func advanceFramePlayback() {
        guard !decodedFrames.isEmpty else {
            stopFramePlayback()
            return
        }

        let next = currentFrameIndex + 1

        if next <= maxFrameIndex {
            currentFrameIndex = next
            currentVideoFrameImage = decodedFrames[min(next, decodedFrames.count - 1)].image
            currentTimeSeconds = decodedFrames[min(next, decodedFrames.count - 1)].timeSeconds
            imageRenderToken += 1
        } else if isVideoLooping {
            setCurrentFrameIndex(0)
            audioPlayer?.play()
        } else {
            stopFramePlayback()
            audioPlayer?.pause()
            videoPlaybackStatus = "Ended"
        }

    }

    private func stopFramePlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isFramePlaybackRunning = false
    }

    private func installAudioEndObserver(for item: AVPlayerItem) {
        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
            self.audioEndObserver = nil
        }

        audioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if self.isVideoLooping {
                    self.setCurrentFrameIndex(0)
                    self.audioPlayer?.play()
                } else {
                    self.stopFramePlayback()
                    self.videoPlaybackStatus = "Ended"
                }
            }
        }
    }

    private func releaseCurrentVideoAccess() {
        stopFramePlayback()

        if let audioEndObserver {
            NotificationCenter.default.removeObserver(audioEndObserver)
            self.audioEndObserver = nil
        }

        audioPlayer?.pause()
        audioPlayer = nil

        if videoSecurityScopedAccessActive,
           let videoSecurityScopedURL {
            videoSecurityScopedURL.stopAccessingSecurityScopedResource()
        }

        videoSecurityScopedURL = nil
        videoSecurityScopedAccessActive = false
    }

    func runVisionExtraction() async {
        diagnostics.log("""
        Run Vision requested:
          videoURL: \(videoURL?.path ?? "nil")
          decodedFrames: \(decodedFrames.count)
          currentImage exists: \(currentVideoFrameImage != nil)
        """)

        guard let videoURL else {
            let reason = "Cannot run Vision: videoURL is nil."
            diagnostics.log(reason)
            status = reason
            lastVisionError = reason
            return
        }

        isWorking = true
        status = "Running Apple Vision pose extraction..."
        lastVisionError = nil

        do {
            let capture = try await exporter.runExtraction(
                videoURL: videoURL,
                sampleFPS: framePlaybackFPS,
                maxFrames: 0
            )

            rawCapture = capture
            normalizedCapture = nil
            smoothedCapture = nil
            fitResult = nil
            maxFrameIndex = max(maxFrameIndex, max(0, capture.frames.count - 1))
            if currentFrameIndex > maxFrameIndex {
                setCurrentFrameIndex(maxFrameIndex)
            }

            let detectedCount = capture.frames.filter { $0.detected }.count
            status = "Vision extraction complete: \(capture.frames.count) frames."
            log("Vision extraction complete: \(capture.frames.count) frames.")
            isWorking = false

            diagnostics.log("""
            Vision extraction success:
              rawCapture set: \(rawCapture != nil)
              frames: \(capture.frames.count)
              detectedFrames: \(detectedCount)
              first frame joints: \(capture.frames.first?.joints.count ?? 0)
              Normalize enabled: \(normalizeDisabledReason == nil)
              Normalize disabled reason: \(normalizeDisabledReason ?? "none")
            """)

            if rawCapture == nil {
                diagnostics.log("ERROR: Vision reported success but rawCapture is nil.")
            }
        } catch {
            rawCapture = nil
            lastVisionError = error.localizedDescription
            status = "Vision extraction failed."
            log("Vision extraction failed: \(error.localizedDescription)")
            isWorking = false

            diagnostics.log("""
            Vision extraction FAILED:
              error: \(error)
              rawCapture set: \(rawCapture != nil)
              Normalize disabled reason: \(normalizeDisabledReason ?? "none")
            """)
        }

    }

    func normalize() {
        diagnostics.log("""
        Normalize requested:
          rawCapture exists: \(rawCapture != nil)
          rawFrames: \(rawCapture?.frames.count ?? 0)
        """)

        guard let rawCapture else {
            let reason = "Cannot normalize: rawCapture is nil."
            diagnostics.log(reason)
            status = reason
            lastNormalizeError = reason
            return
        }

        guard !rawCapture.frames.isEmpty else {
            let reason = "Cannot normalize: rawCapture has 0 frames."
            diagnostics.log(reason)
            status = reason
            lastNormalizeError = reason
            return
        }

        normalizedCapture = PoseNormalizer.normalize(rawCapture: rawCapture)
        smoothedCapture = nil
        fitResult = nil
        maxFrameIndex = max(maxFrameIndex, max(0, (normalizedCapture?.frames.count ?? 0) - 1))
        let frameCount = normalizedCapture?.frames.count ?? 0
        let firstJointCount = normalizedCapture?.frames.first?.joints.count ?? 0
        lastNormalizeError = nil
        status = "Normalized to Meshy24: \(frameCount) frames."
        log("Normalized \(rawCapture.frames.count) frames to Meshy/Jock 24.")

        diagnostics.log("""
        Normalize success:
          normalizedCapture set: \(normalizedCapture != nil)
          frames: \(frameCount)
          first frame joint count: \(firstJointCount)
          expected canonical count: \(CanonicalRig.jointNames.count)
          Smoothing enabled: \(smoothingDisabledReason == nil)
          Smoothing disabled reason: \(smoothingDisabledReason ?? "none")
        """)

        if normalizedCapture == nil {
            diagnostics.log("ERROR: Normalize reported success but normalizedCapture is nil.")
        }

    }

    func smooth() {
        diagnostics.log("""
        Smoothing requested:
          normalizedCapture exists: \(normalizedCapture != nil)
          normalizedFrames: \(normalizedCapture?.frames.count ?? 0)
          smoothing global: \(smoothingSettings.globalEnabled)
          smoothing strength: \(smoothingSettings.strength)
        """)

        guard let normalizedCapture else {
            let reason = "Cannot smooth: normalizedCapture is nil."
            diagnostics.log(reason)
            status = reason
            lastSmoothingError = reason
            return
        }

        guard !normalizedCapture.frames.isEmpty else {
            let reason = "Cannot smooth: normalizedCapture has 0 frames."
            diagnostics.log(reason)
            status = reason
            lastSmoothingError = reason
            return
        }

        let settings = SmoothedMeshyPoseCapture.SmoothingSettings(
            globalEnabled: smoothingPreviewEnabled,
            strength: smoothingStrength,
            windowRadius: smoothingWindowRadius,
            missingInterpolationEnabled: smoothingSettings.missingInterpolationEnabled,
            confidenceWeighted: smoothingSettings.confidenceWeighted,
            perJointEnabled: smoothingSettings.perJointEnabled
        )
        smoothingSettings = settings

        smoothedCapture = PoseSmoother2D.smooth(
            normalized: normalizedCapture,
            settings: settings
        )
        fitResult = nil
        let frameCount = smoothedCapture?.frames.count ?? 0
        let firstJointCount = smoothedCapture?.frames.first?.joints.count ?? 0
        let firstDeltaMagnitude: Double = {
            guard let joint = smoothedCapture?.frames.first?.joints.values.first else {
                return 0
            }

            return hypot(joint.deltaX, joint.deltaY)
        }()

        lastSmoothingError = nil
        status = "Smoothing complete: \(frameCount) frames."
        log("Smoothing complete: strength \(String(format: "%.2f", smoothingStrength)), radius \(smoothingWindowRadius).")

        diagnostics.log("""
        Smoothing success:
          smoothedCapture set: \(smoothedCapture != nil)
          frames: \(frameCount)
          first frame joint count: \(firstJointCount)
          first delta magnitude: \(firstDeltaMagnitude)
        """)

        if smoothedCapture == nil {
            diagnostics.log("ERROR: Smoothing reported success but smoothedCapture is nil.")
        }
    }

    func recomputeSmoothingIfAvailable() {
        guard normalizedCapture != nil else { return }
        smooth()
    }

    func importRigProfile() {
        guard let url = FilePanelHelpers.openJSONURL() else { return }

        do {
            rigProfile = try RigProfileLoader.loadRigProfile(from: url)
            reportRigValidation(source: url.lastPathComponent)
        } catch {
            status = "Rig import failed."
            log("Rig import failed: \(error.localizedDescription)")
        }
    }

    func loadDefaultRigProfile() {
        do {
            rigProfile = try RigProfileLoader.loadBundledDefaultProfile()
            reportRigValidation(source: "bundled Meshy24 placeholder")
        } catch {
            status = "Default rig load failed."
            log("Default rig load failed: \(error.localizedDescription)")
        }
    }

    func importUSDZRig() {
        diagnostics.log("Load USDZ Rig requested.")

        guard let url = FilePanelHelpers.openRigAssetURL() else {
            diagnostics.log("Rig load canceled by user.")
            rigImportStatus = "Rig load canceled."
            status = rigImportStatus
            log(rigImportStatus)
            return
        }

        diagnostics.log("Selected rig: \(url.path)")

        importedRigScene = nil
        rigImportStatus = "Loading rig: \(url.lastPathComponent)..."
        status = rigImportStatus
        log(rigImportStatus)

        let didAccess = url.startAccessingSecurityScopedResource()
        diagnostics.log("Rig security scoped access: \(didAccess)")

        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(
                    domain: "GravitasRotoMotion",
                    code: 4101,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Selected rig file does not exist: \(url.path)"
                    ]
                )
            }

            let rig = try USDZRigSceneLoader.loadRigScene(
                from: url,
                defaultOpacity: CGFloat(rigOpacity)
            )

            importedRigScene = rig
            showImportedRigModel = rig.geometryNodeCount > 0
            lastRigError = nil
            if let measuredProfile = rig.measuredRigProfile {
                rigProfile = measuredProfile
            }

            if rig.validation.valid {
                rigImportStatus = """
                Loaded rig: \(url.lastPathComponent)
                Geometry nodes: \(rig.geometryNodeCount)
                Required joints valid.
                Matched joints: \(rig.skeletonJointNames.count)
                """
            } else {
                let missing = rig.validation.missingRequiredJoints.joined(separator: ", ")
                rigImportStatus = """
                Loaded model: \(url.lastPathComponent)
                Geometry nodes: \(rig.geometryNodeCount)
                Matched joints: \(rig.skeletonJointNames.count)
                Model loaded; skeleton mapping missing required joints: \(missing)
                """
            }

            status = rigImportStatus
            log(rigImportStatus)
            if rig.measuredRigProfile != nil {
                log("Derived measured rig profile from imported USD scene nodes.")
            }

            diagnostics.log("""
            Rig load success:
              importedRigScene set: \(importedRigScene != nil)
              geometryNodes: \(rig.geometryNodeCount)
              matchedJoints: \(rig.skeletonJointNames.count)
              missingRequired: \(rig.validation.missingRequiredJoints.joined(separator: ", "))
              showImportedRigModel: \(showImportedRigModel)
            """)

            print(
                """
                [RotoMotion Rig] Loaded rig
                  url: \(url.path)
                  geometries: \(rig.geometryNodeCount)
                  matched: \(rig.skeletonJointNames.count)
                  missingRequired: \(rig.validation.missingRequiredJoints.joined(separator: ", "))
                  nodeCount: \(rig.validation.allImportedNodeNames.count)
                """
            )
        } catch {
            importedRigScene = nil
            lastRigError = error.localizedDescription
            rigImportStatus = """
            Rig/model load failed: \(url.lastPathComponent)
            \(error.localizedDescription)
            """
            status = rigImportStatus
            log(rigImportStatus)

            diagnostics.log("""
            Rig load FAILED:
              url: \(url.path)
              error: \(error)
              importedRigScene set: \(importedRigScene != nil)
            """)

            print(
                """
                [RotoMotion Rig] FAILED
                  url: \(url.path)
                  error: \(error)
                """
            )
        }
    }

    func updateImportedRigOpacity() {
        guard let importedRigScene else { return }

        USDZRigSceneLoader.applyTransparency(
            rootNode: importedRigScene.rootNode,
            opacity: CGFloat(rigOpacity)
        )
    }

    func runFit() {
        guard let normalizedCapture else {
            log("Need normalized capture before rig fitting.")
            return
        }

        guard let rigProfile else {
            log("Import a rig profile before fitting.")
            return
        }

        fitResult = ConstrainedRigFitter.fit(
            normalized: normalizedCapture,
            smoothed: smoothedCapture,
            rigProfile: rigProfile,
            settings: fitSettings,
            groundPlane: groundPlane
        )
        status = "Rig fit complete."
        log("Constrained rig fit complete: \(fitResult?.frames.count ?? 0) frames.")
    }

    func saveRawJSON() {
        guard let rawCapture else {
            log("No raw capture to save.")
            return
        }

        saveJSON(rawCapture, defaultFileName: "capture_raw_vision.json", label: "raw Vision")
    }

    func saveNormalizedJSON() {
        guard let normalizedCapture else {
            log("No normalized capture to save.")
            return
        }

        saveJSON(normalizedCapture, defaultFileName: "capture_normalized_meshy24.json", label: "normalized Meshy24")
    }

    func saveSmoothedJSON() {
        guard let smoothedCapture else {
            log("No smoothed capture to save.")
            return
        }

        saveJSON(smoothedCapture, defaultFileName: "capture_smoothed_meshy24.json", label: "smoothed Meshy24")
    }

    func saveRigProfileJSON() {
        guard let rigProfile else {
            log("No rig profile to save.")
            return
        }

        saveJSON(rigProfile, defaultFileName: "rig_profile_meshy24.json", label: "rig profile")
    }

    func saveFitJSON() {
        guard let fitResult else {
            log("No fit result to save.")
            return
        }

        saveJSON(fitResult, defaultFileName: "capture_fit_meshy24.json", label: "fit result")
    }

    func exportJockAnim() {
        guard let fitResult else {
            log("Run rig fit before JockAnim export.")
            return
        }

        guard let url = FilePanelHelpers.saveJSONURL(
            defaultDirectory: outputDirectoryURL,
            defaultFileName: "rotomotion_test.jockanim.json"
        ) else {
            return
        }

        outputDirectoryURL = url.deletingLastPathComponent()

        do {
            try JockAnimExporter.export(
                fitResult: fitResult,
                clipID: RotoMotionProjectStore.defaultClipID(for: videoURL),
                displayName: videoURL?.deletingPathExtension().lastPathComponent ?? "RotoMotion Test",
                fps: rawCapture?.extraction.sampleFPS ?? sampleFPS,
                looping: false,
                to: url
            )
            status = "JockAnim export complete."
            log("Wrote \(url.lastPathComponent)")
        } catch {
            status = "JockAnim export failed."
            log("JockAnim export failed: \(error.localizedDescription)")
        }
    }

    func chooseOutputDirectory() {
        guard let url = FilePanelHelpers.chooseOutputDirectory() else { return }

        outputDirectoryURL = url
        log("Output directory set to \(url.path)")
    }

    func handlePlaybackTimeChange(_ seconds: Double) {
        currentTimeSeconds = seconds

        let frames = rawCapture?.frames
        guard let frames, !frames.isEmpty else {
            return
        }

        let nearestIndex = frames.indices.min { lhs, rhs in
            abs(frames[lhs].timeSeconds - seconds) < abs(frames[rhs].timeSeconds - seconds)
        }

        if let nearestIndex, nearestIndex != currentFrameIndex {
            setCurrentFrameIndex(nearestIndex)
        }
    }

    func setCurrentFrameIndex(_ index: Int) {
        guard !decodedFrames.isEmpty else {
            currentFrameIndex = 0
            currentVideoFrameImage = nil
            currentTimeSeconds = 0
            imageRenderToken += 1
            diagnostics.log("setCurrentFrameIndex ignored: decodedFrames empty.")
            return
        }

        let clamped = max(0, min(maxFrameIndex, min(index, decodedFrames.count - 1)))

        currentFrameIndex = clamped
        currentVideoFrameImage = decodedFrames[clamped].image
        currentTimeSeconds = decodedFrames[clamped].timeSeconds
        imageRenderToken += 1

        diagnostics.log("""
        setCurrentFrameIndex:
          requested: \(index)
          clamped: \(clamped)
          image exists: \(currentVideoFrameImage != nil)
          imageRenderToken: \(imageRenderToken)
          image size: \(String(describing: currentVideoFrameImage?.size))
        """)
    }

    func setCurrentFrameIndex(_ index: Int, seekPlayer: Bool) {
        setCurrentFrameIndex(index)
    }

    func stepFrame(_ delta: Int) {
        setCurrentFrameIndex(currentFrameIndex + delta)
    }

    func debugSaveCurrentFramePNG() {
        guard let image = currentVideoFrameImage else {
            diagnostics.log("Debug PNG failed: currentVideoFrameImage nil.")
            return
        }

        guard let tiff = image.tiffRepresentation else {
            diagnostics.log("Debug PNG failed: no TIFF representation.")
            return
        }

        guard let bitmap = NSBitmapImageRep(data: tiff) else {
            diagnostics.log("Debug PNG failed: no bitmap rep.")
            return
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            diagnostics.log("Debug PNG failed: no PNG representation.")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotomotion_current_frame_debug.png")

        do {
            try png.write(to: url)
            diagnostics.log("Saved debug frame PNG: \(url.path)")
            NSWorkspace.shared.open(url)
        } catch {
            diagnostics.log("Debug PNG save failed: \(error.localizedDescription)")
        }
    }

    func resetGroundPlane() {
        groundPlane.reset()
        fitSettings.useGroundConstraint = groundPlane.constraintEnabled
        fitResult = nil
        status = "Ground plane reset."
        log(status)
    }

    private func reportRigValidation(source: String) {
        guard let rigProfile else { return }

        let validation = rigProfile.validate()

        if validation.valid {
            status = "Rig profile loaded and valid."
            log("Loaded rig profile from \(source).")
        } else {
            status = "Rig profile missing required landmarks."
            log("Rig missing: \(validation.missingRequiredJoints.joined(separator: ", "))")
        }
    }

    private func saveJSON<T: Encodable>(
        _ value: T,
        defaultFileName: String,
        label: String
    ) {
        guard let url = FilePanelHelpers.saveJSONURL(
            defaultDirectory: outputDirectoryURL,
            defaultFileName: defaultFileName
        ) else {
            return
        }

        outputDirectoryURL = url.deletingLastPathComponent()

        do {
            try JSONCoding.writePretty(value, to: url)
            status = "Saved \(label)."
            log("Wrote \(url.lastPathComponent)")
        } catch {
            status = "Save failed."
            log("\(label) save failed: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        logLines.append(message)

        if logLines.count > 100 {
            logLines.removeFirst(logLines.count - 100)
        }
    }
}
