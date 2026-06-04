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
    @Published var player: AVPlayer?

    @Published var rawCapture: RawVisionPoseCapture?
    @Published var normalizedCapture: NormalizedMeshyPoseCapture?
    @Published var smoothedCapture: SmoothedMeshyPoseCapture?
    @Published var rigProfile: RigProfile?
    @Published var importedRigScene: ImportedRigScene?
    @Published var fitResult: RigFitResult?

    @Published var currentFrameIndex = 0
    @Published var currentTimeSeconds = 0.0

    @Published var sampleFPS = 24.0
    @Published var maxFrames = 0

    @Published var showRawVisionPoints = true
    @Published var showNormalizedMeshyPoints = true
    @Published var showSmoothedMeshyPoints = true
    @Published var showSmoothingDeltaVectors = true
    @Published var showImportedRigModel = true
    @Published var showImportedRigSkeleton = true
    @Published var showFittedRig = true

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

    private let exporter = RotoMotionExporter()

    var frameCount: Int {
        [
            rawCapture?.frames.count,
            normalizedCapture?.frames.count,
            smoothedCapture?.frames.count,
            fitResult?.frames.count
        ]
        .compactMap { $0 }
        .max() ?? 0
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
        guard let url = FilePanelHelpers.openVideoURL() else { return }

        videoURL = url
        outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        rawCapture = nil
        normalizedCapture = nil
        smoothedCapture = nil
        fitResult = nil
        project = nil
        currentFrameIndex = 0
        currentTimeSeconds = 0

        let player = AVPlayer(url: url)
        self.player = player
        player.play()

        status = "Loaded video: \(url.lastPathComponent)"
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

    func runVisionExtraction() async {
        guard let videoURL else {
            log("No video selected.")
            return
        }

        isWorking = true
        status = "Running Vision extraction..."

        do {
            let capture = try await exporter.runExtraction(
                videoURL: videoURL,
                sampleFPS: max(sampleFPS, 1.0),
                maxFrames: maxFrames
            )

            rawCapture = capture
            normalizedCapture = nil
            smoothedCapture = nil
            fitResult = nil
            setCurrentFrameIndex(0, seekPlayer: true)
            status = "Vision extraction complete."
            log("Vision extraction complete: \(capture.frames.count) frames.")
        } catch {
            status = "Vision extraction failed."
            log("Vision extraction failed: \(error.localizedDescription)")
        }

        isWorking = false
    }

    func normalize() {
        guard let rawCapture else {
            log("Run Vision extraction before normalization.")
            return
        }

        normalizedCapture = PoseNormalizer.normalize(rawCapture: rawCapture)
        smoothedCapture = nil
        fitResult = nil
        status = "Normalized to Meshy/Jock 24."
        log("Normalized \(rawCapture.frames.count) frames to Meshy/Jock 24.")

        if smoothingPreviewEnabled {
            smooth()
        }
    }

    func smooth() {
        guard let normalizedCapture else {
            log("Normalize before smoothing.")
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
        status = "Smoothing complete."
        log("Smoothing complete: strength \(String(format: "%.2f", smoothingStrength)), radius \(smoothingWindowRadius).")
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
        guard let url = FilePanelHelpers.openRigAssetURL() else { return }

        do {
            let rig = try USDZRigSceneLoader.loadRigScene(
                from: url,
                defaultOpacity: CGFloat(rigOpacity)
            )

            importedRigScene = rig
            if let measuredProfile = rig.measuredRigProfile {
                rigProfile = measuredProfile
            }

            if rig.validation.valid {
                rigImportStatus = "Loaded rig: \(url.lastPathComponent). Required Meshy24 joints valid."
            } else {
                let missing = rig.validation.missingRequiredJoints.joined(separator: ", ")
                rigImportStatus = "Loaded rig: \(url.lastPathComponent). Missing required: \(missing). Matched joints: \(rig.skeletonJointNames.count)."
            }

            status = rigImportStatus
            log(rigImportStatus)
            if rig.measuredRigProfile != nil {
                log("Derived measured rig profile from imported USD scene nodes.")
            }
        } catch {
            rigImportStatus = "USDZ rig import failed: \(error.localizedDescription)"
            status = rigImportStatus
            log(rigImportStatus)
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
            settings: fitSettings
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
            setCurrentFrameIndex(nearestIndex, seekPlayer: false)
        }
    }

    func setCurrentFrameIndex(_ index: Int, seekPlayer: Bool) {
        guard frameCount > 0 else {
            currentFrameIndex = 0
            return
        }

        let clamped = min(max(index, 0), frameCount - 1)
        currentFrameIndex = clamped

        if let frame = currentRawFrame {
            currentTimeSeconds = frame.timeSeconds
        }

        guard seekPlayer, let frame = currentRawFrame else {
            return
        }

        player?.seek(
            to: CMTime(seconds: frame.timeSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
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
