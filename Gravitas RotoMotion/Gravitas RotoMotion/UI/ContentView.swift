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
    @AppStorage("com.gravitas.rotomotion.uiLoop") private var uiLoop = true
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackStartHostTime: Date?
    @State private var playbackStartVideoTime = 0.0
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
            roto.refreshSelectedJointEulerFields()
        }
        .onChange(of: roto.selectedRotationJoint) { _, _ in
            roto.refreshSelectedJointEulerFields()
        }
        .onDisappear {
            releaseUIVideoAccess()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Open Session") {
                openRotoMotionSessionFromContentView()
            }

            Button("Save Session") {
                roto.saveRotoMotionSession()
                uiStatus = roto.status
            }

            Button("Save Session As") {
                roto.saveRotoMotionSessionAs()
                uiStatus = roto.status
            }

            Divider()
                .frame(height: 22)

            Button("Open Video") {
                openVideoDirectlyInContentView()
            }
            .buttonStyle(.borderedProminent)

            Button("Open Spatial Video") {
                openSpatialVideoDirectlyInContentView()
            }

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
                rightRawFrame: currentRightRawFrame,
                rightNormalizedFrame: currentRightNormalizedFrame,
                smoothedFrame: nil,
                stereoJointFrame: roto.spatialStereoAvailable ? roto.currentStereoJointFrame : nil,
                conditionedStereoFrame: roto.currentConditionedStereoFrame,
                jointDepthEvidenceFrame: roto.currentJointDepthEvidenceFrame,
                disparityPreviewFrame: roto.currentSpatialDisparityPreviewFrame,
                fusedStereoTargetFrame: roto.currentFusedStereoTargetFrame,
                groundPlane: roto.groundPlane,
                raySolveResult: roto.currentRaySolveResult,
                raySolvedFrame: roto.currentRaySolvedFrame,
                skinnedRigSession: roto.skinnedRigSession,
                cameraFOVDegrees: roto.activeViewportVerticalFOVDegrees,
                cameraProfileName: roto.activeViewportCameraProfileName,
                currentVideoPlaneZ: roto.currentVideoPlaneZ,
                referenceRigScaleMultiplier: roto.referenceRigScaleMultiplier,
                referenceRigX: roto.referenceRigX,
                referenceRigY: roto.referenceRigY,
                referenceRigZ: roto.referenceRigZ,
                referenceRigYawDegrees: roto.referenceRigYawDegrees,
                applySolvedPoseToReferenceRig: roto.applySolvedPoseToReferenceRig,
                rigRotationApplyMode: roto.rigRotationApplyMode,
                rotationOverrideLayer: roto.rotationOverrideLayer,
                heldRotationOverrideEulerXYZByJoint: roto.heldRotationOverrideEulerXYZByJoint,
                liveRotationOverrideEulerXYZByJoint: roto.liveRotationOverrideEulerXYZByJoint,
                liveRotationOverridesActive: roto.isRotationGizmoDragging,
                rotationOverrideRevision: roto.rotationOverrideRevision,
                showRawVision: roto.showRawVisionPoints,
                showNormalizedMeshy: roto.showNormalizedMeshyPoints,
                showRightEyeVisionOverlay: roto.shouldShowRightEyeVisionOverlay,
                showRightEyeNormalizedOverlay: roto.shouldShowRightEyeNormalizedOverlay,
                showSmoothedMeshy: false,
                showStereo3DSkeleton: roto.showStereo3DSkeleton && roto.spatialStereoAvailable,
                showConditionedStereoSkeleton: roto.showConditionedStereoSkeleton && roto.conditionedStereoJointCapture != nil,
                showStereoReprojectionOverlay: roto.spatialStereoAvailable,
                showJointDepthValidationOverlay: roto.showJointDepthValidationOverlay && roto.jointDepthEvidenceCapture != nil,
                showDisparityOnImagePlane: roto.showDisparityOnImagePlane && roto.spatialDisparityPreviewCapture != nil,
                selectedDisparityPlateOverlay: roto.selectedDisparityPlateOverlay,
                disparityPlateOverlayOpacity: roto.disparityPlateOverlayOpacity,
                showFusedStereoTargets: roto.showFusedStereoTargets && roto.fusedStereoJointTargetCapture != nil,
                showSpatialTargetBalls: roto.showSpatialTargetBalls,
                spatialTargetBallScale: roto.spatialTargetBallScale,
                showGroundPlane: roto.groundPlane.visible,
                showVisionRays: roto.showVisionRays,
                showRaySolvedRig: roto.showDebugSolvedSkeleton,
                showSkinnedRig: roto.showSkinnedRig,
                showSkinnedGeometry: roto.showSkinnedGeometry,
                showRotationGizmo: roto.showRotationGizmo,
                stereoMetersToRigSceneUnits: roto.stereoMetersToRigSceneUnits,
                stereoToRigAlignment: roto.stereoToRigAlignment,
                solveTargetMode: roto.solveTargetMode,
                spatialRayPinDepthMode: roto.spatialRayPinDepthMode,
                rotationGizmoSpace: roto.rotationGizmoSpace,
                selectedRotationJoint: roto.selectedRotationJoint,
                onRotationGizmoEulerChanged: { joint, euler in
                    DispatchQueue.main.async {
                        roto.setViewportRotationOverride(joint: joint, eulerXYZ: euler)
                        uiStatus = roto.status
                    }
                },
                onRotationGizmoStatus: { status in
                    DispatchQueue.main.async {
                        roto.rotationGizmoStatus = status
                    }
                },
                onRotationGizmoDragEnded: {
                    DispatchQueue.main.async {
                        roto.endViewportRotationGizmoDrag()
                        uiStatus = roto.status
                    }
                },
                onVideoPlaneSizeChanged: { size in
                    DispatchQueue.main.async {
                        roto.currentVideoPlaneSize = size
                    }
                },
                onReferenceRigVisibilityStatusChanged: { status in
                    DispatchQueue.main.async {
                        if roto.referenceRigVisibilityStatus != status {
                            roto.referenceRigVisibilityStatus = status
                            roto.diagnostics.log(status)
                        }
                    }
                },
                onSpatialSolveTrace: { trace in
                    Task { @MainActor in
                        roto.updateSpatialSolveTrace(trace)
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            timelineControls
        }
    }

    private var timelineControls: some View {
        VStack(spacing: 4) {
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

            RotationKeyTimelineMarkers(
                frameCount: uiDecodedFrames.count,
                keyframes: roto.rotationOverrideLayer.keyframesByJoint[roto.selectedRotationJoint] ?? []
            )
            .frame(height: 16)
        }
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Video") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Input Mode", selection: $roto.captureMode) {
                            ForEach(RotoMotionCaptureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("File: \(uiVideoURL?.lastPathComponent ?? "none")")
                        Text("Source frames: \(uiDecodedFrames.count)")
                        Text("Current image: \(uiCurrentImage == nil ? "nil" : "yes")")
                        Text("Current time: \(String(format: "%.3f", currentUIVideoTimeSeconds))s")
                        Text("Visual FPS: \(String(format: "%.3f", RotoVideoFrameCache.estimatedFPS(frames: uiDecodedFrames)))")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                spatialVideoPanel

                sessionFilePanel

                viewportPanel

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

                referenceRigPanel

                rayRigSolvePanel

                sessionPoseSourcePanel

                rotationAuthoringPanel

                usdzRetargetExportPanel

                diagnosticsPanel
            }
            .padding(10)
        }
    }

    private var viewportPanel: some View {
        GroupBox("Viewport") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Camera", selection: $roto.cameraProfile) {
                    ForEach(CameraProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.menu)

                Text(
                    "FOV vertical \(String(format: "%.1f", roto.activeCameraIntrinsics.verticalFOVDegrees))° / horizontal \(String(format: "%.1f", roto.activeCameraIntrinsics.horizontalFOVDegrees))°"
                )
                .foregroundStyle(.secondary)

            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionFilePanel: some View {
        GroupBox("Session File") {
            VStack(alignment: .leading, spacing: 6) {
                Text(roto.currentSessionURL?.lastPathComponent ?? "Unsaved RotoMotion session")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(roto.sessionIsDirty ? "Unsaved changes" : "Saved")
                    .font(.caption2)
                    .foregroundStyle(roto.sessionIsDirty ? .orange : .secondary)

                Text(roto.sessionFileStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var spatialVideoPanel: some View {
        GroupBox("Spatial Video Depth") {
            VStack(alignment: .leading, spacing: 8) {
                Text(roto.spatialVideoURL?.lastPathComponent ?? "No spatial video selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Manual Spatial Camera Overrides", isOn: $roto.useManualSpatialCameraOverrides)

                HStack {
                    Text("Baseline m")
                        .frame(width: 78, alignment: .leading)

                    TextField(
                        "baseline",
                        value: $roto.spatialBaselineMeters,
                        format: .number.precision(.fractionLength(5))
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!roto.useManualSpatialCameraOverrides)
                }

                HStack {
                    Text("H FOV")
                        .frame(width: 78, alignment: .leading)

                    TextField(
                        "horizontal",
                        value: $roto.spatialHorizontalFOVDegrees,
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!roto.useManualSpatialCameraOverrides)

                    Text("°")
                }

                HStack {
                    Text("V FOV")
                        .frame(width: 78, alignment: .leading)

                    TextField(
                        "vertical",
                        value: $roto.spatialVerticalFOVDegrees,
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!roto.useManualSpatialCameraOverrides)

                    Text("°")
                }

                Picker("Stereo Y", selection: $roto.stereoYConvention) {
                    ForEach(NormalizedImageYConvention.allCases) { convention in
                        Text(convention.displayName).tag(convention)
                    }
                }
                .pickerStyle(.segmented)

                Button("Run Vision") {
                    Task {
                        await roto.runVisionOnSpatialVideo()
                        uiDecodedFrames = roto.decodedFrames
                        uiCurrentFrameIndex = 0
                        uiCurrentImage = uiDecodedFrames.first?.image
                        uiStatus = roto.status
                        pipelineRenderToken += 1
                    }
                }
                .disabled(roto.isWorking)

                Button("Build Stereo Joint Depth") {
                    roto.rebuildStereoJointDepthFromCurrentSettings()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(roto.normalizedLeftCapture == nil || roto.normalizedRightCapture == nil)

                Button("Build Disparity Map") {
                    Task {
                        await roto.buildSpatialDisparityMaps()
                        uiStatus = roto.status
                        pipelineRenderToken += 1
                    }
                }
                .disabled(
                    roto.isWorking ||
                    roto.isBuildingSpatialDisparity ||
                    roto.captureMode != .spatialVideo ||
                    roto.spatialLeftEyeFrames.isEmpty ||
                    roto.spatialRightEyeFrames.isEmpty ||
                    roto.spatialVideoMetadata == nil
                )

                if roto.isBuildingSpatialDisparity ||
                    roto.spatialDisparityBuildProgress > 0 ||
                    roto.spatialDisparityBuildProgressText != "No disparity build running." {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(
                            value: roto.spatialDisparityBuildProgress,
                            total: 1.0
                        )
                        .progressViewStyle(.linear)

                        Text(roto.spatialDisparityBuildProgressText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                GroupBox("Disparity Build") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(roto.spatialDisparityProgressTitle)
                                .font(.caption)
                                .bold()

                            Spacer()

                            Text("\(Int(roto.spatialDisparityProgressFraction * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }

                        ProgressView(value: roto.spatialDisparityProgressFraction)
                            .tint(.green)

                        Text(roto.spatialDisparityProgressDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("""
                        phase: \(roto.spatialDisparityBuildPhase.rawValue)
                        frame: \(roto.spatialDisparityCurrentFrame)/\(roto.spatialDisparityTotalFrames)
                        row: \(roto.spatialDisparityCurrentRow)/\(roto.spatialDisparityTotalRows)
                        elapsed: \(String(format: "%.1f", roto.spatialDisparityElapsedSeconds))s
                        remaining: \(String(format: "%.1f", roto.spatialDisparityEstimatedRemainingSeconds))s
                        last valid: \(String(format: "%.2f", roto.spatialDisparityLastFrameValidPercent))%
                        """)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GroupBox("Spatial Solve") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(roto.spatialSolveProgressTitle)
                                .font(.caption)
                                .bold()

                            Spacer()

                            Text("\(Int(roto.spatialSolveProgressFraction * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }

                        ProgressView(value: roto.spatialSolveProgressFraction)
                            .tint(.green)

                        Text(roto.spatialSolveProgressDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GroupBox("Disparity Map Proof") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Build Disparity Debug Frame") {
                                Task {
                                    await roto.buildSpatialDisparityDebugFrame()
                                    uiStatus = roto.status
                                }
                            }
                            .disabled(
                                roto.isWorking ||
                                roto.isBuildingSpatialDisparity ||
                                roto.captureMode != .spatialVideo ||
                                roto.spatialLeftEyeFrames.isEmpty ||
                                roto.spatialRightEyeFrames.isEmpty ||
                                roto.spatialVideoMetadata == nil
                            )

                            TextField(
                                "Frame",
                                value: $roto.spatialDisparityDebugFrameIndex,
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        }

                        Text(roto.spatialDisparityDebugStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let image = roto.spatialDisparityDepthPreviewImage {
                            Text("Depth Preview")
                                .font(.caption)

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(maxHeight: 160)
                        }

                        if let image = roto.spatialDisparityConfidencePreviewImage {
                            Text("Confidence Preview")
                                .font(.caption)

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(maxHeight: 120)
                        }

                        if let image = roto.spatialDisparityRawPreviewImage {
                            Text("Raw Disparity Preview")
                                .font(.caption)

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(maxHeight: 120)
                        }

                        Text("Dump: \(roto.spatialDisparityDebugDirectoryPath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GroupBox("Disparity Plate Overlay") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Show Disparity On Plate", isOn: $roto.showDisparityOnImagePlane)
                            .disabled(roto.spatialDisparityPreviewCapture == nil)

                        Picker("Map", selection: $roto.selectedDisparityPlateOverlay) {
                            ForEach(DisparityPlateOverlayKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(roto.spatialDisparityPreviewCapture == nil)

                        Slider(
                            value: $roto.disparityPlateOverlayOpacity,
                            in: 0...1
                        )
                        .disabled(roto.spatialDisparityPreviewCapture == nil)

                        Text(roto.spatialDisparityStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Stereo 3D Skeleton", isOn: $roto.showStereo3DSkeleton)
                    .disabled(!roto.spatialStereoAvailable)

                Toggle("Joint Depth Validation", isOn: $roto.showJointDepthValidationOverlay)
                    .disabled(roto.jointDepthEvidenceCapture == nil)

                Toggle("Fused Stereo Targets", isOn: $roto.showFusedStereoTargets)
                    .disabled(roto.fusedStereoJointTargetCapture == nil)

                Toggle("Spatial Target Balls", isOn: $roto.showSpatialTargetBalls)

                if roto.showSpatialTargetBalls {
                    HStack {
                        Text("Target Size")
                            .font(.caption)

                        Slider(value: $roto.spatialTargetBallScale, in: 0.15...1.0)
                    }
                }

                Text("Left frames: \(roto.leftEyeFrames.count), right frames: \(roto.rightEyeFrames.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Stereo frames: \(roto.stereoJointCapture?.frames.count ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(roto.spatialStereoAvailable ? "Stereo 3D skeleton available." : roto.spatialDepthStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.spatialDisparityStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.spatialSolveStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.fusedStereoTargetStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.stereoAlignmentStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.spatialVideoStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.spatialDecodeStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.stereoVisionStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SpatialStereoDiagnosticView(
                    leftImage: roto.spatialLeftPreviewImage,
                    rightImage: roto.spatialRightPreviewImage,
                    leftCount: roto.spatialLeftEyeFrames.count,
                    rightCount: roto.spatialRightEyeFrames.count,
                    dumpDirectory: roto.spatialDumpDirectoryPath,
                    diagnostics: roto.spatialDiagnostics
                )
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var referenceRigPanel: some View {
        GroupBox("Reference Rig") {
            VStack(alignment: .leading, spacing: 6) {
                Button("Choose Reference / Solve USDZ") {
                    roto.chooseReferenceSolveUSDZ()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(roto.referenceSolveUSDZURL?.lastPathComponent ?? "No reference USDZ selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Reference Visible", isOn: $roto.showSkinnedRig)

                Toggle("Reference Geometry", isOn: $roto.showSkinnedGeometry)
                    .disabled(!roto.showSkinnedRig)

                Text(roto.skinnedRigStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedRotationKeyCount: Int {
        roto.rotationOverrideLayer.keyframesByJoint[roto.selectedRotationJoint]?.count ?? 0
    }

    private var rotationAuthoringPanel: some View {
        GroupBox("Rotation Authoring") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Joint", selection: $roto.selectedRotationJoint) {
                    ForEach(roto.editableJointNames, id: \.self) { joint in
                        Text(joint).tag(joint)
                    }
                }
                .pickerStyle(.menu)

                GroupBox("Selected Joint Euler Override") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(roto.selectedRotationJoint)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollWheelDegreeField(
                            label: "X",
                            value: $roto.selectedJointEulerDegreesX,
                            onValueChanged: { newValue in
                                roto.setSelectedJointEulerDegrees(x: newValue)
                            }
                        )

                        ScrollWheelDegreeField(
                            label: "Y",
                            value: $roto.selectedJointEulerDegreesY,
                            onValueChanged: { newValue in
                                roto.setSelectedJointEulerDegrees(y: newValue)
                            }
                        )

                        ScrollWheelDegreeField(
                            label: "Z",
                            value: $roto.selectedJointEulerDegreesZ,
                            onValueChanged: { newValue in
                                roto.setSelectedJointEulerDegrees(z: newValue)
                            }
                        )

                        Text("Euler XYZ override. No W / quaternion channel.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Gizmo", selection: $roto.rotationGizmoSpace) {
                    ForEach(RotationGizmoSpace.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Rotation Gizmo", isOn: $roto.showRotationGizmo)

                Toggle("Clean Keys Mode: Replace Keys With One", isOn: $roto.cleanRotationKeysEnabled)

                Text("\(roto.selectedRotationJoint) rotation keys: \(selectedRotationKeyCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Add Rotation Key") {
                    roto.addRotationKeyForSelectedJoint()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Button("Clear Rotation Keys For Joint") {
                    roto.clearRotationKeysForSelectedJoint()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(selectedRotationKeyCount == 0)

                Button("Clear All Rotation Override For Joint") {
                    roto.clearAllRotationOverrideForSelectedJoint()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(
                    selectedRotationKeyCount == 0 &&
                        roto.heldRotationOverrideEulerXYZByJoint[roto.selectedRotationJoint] == nil &&
                        roto.liveRotationOverrideEulerXYZByJoint[roto.selectedRotationJoint] == nil
                )

                Text(roto.rotationAuthoringStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.rotationGizmoStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionPoseSourcePanel: some View {
        GroupBox("Session Pose Source") {
            VStack(alignment: .leading, spacing: 4) {
                Text(roto.sessionPoseSource.rawValue)
                    .font(.caption)
                    .monospaced()

                Text(roto.sessionPoseStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Inspect Current Joint Frame") {
                    roto.inspectCurrentJointFrame()
                }
                .disabled(roto.skinnedRigSession == nil || roto.rayAnimationSolveResult == nil)

                Button("Log Current Pose Chains") {
                    roto.logCurrentPoseChains()
                }
                .disabled(roto.skinnedRigSession == nil || roto.currentRaySolvedFrame == nil)

                Text(roto.jointDebugStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usdzRetargetExportPanel: some View {
        GroupBox("USDZ Retarget Export") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Target Model USDZ")
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("Optional. If empty, export will use the Reference USDZ or ask for a file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose Target Model USDZ") {
                    roto.chooseTargetCharacterUSDZ()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(roto.targetCharacterUSDZURL?.lastPathComponent ?? "No target model USDZ")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Clip ID", text: $roto.retargetClipID)
                    .textFieldStyle(.roundedBorder)

                Toggle("Include Hips Translation", isOn: $roto.includeHipsTranslationInUSDZ)

                Button("Check OpenUSD Tools") {
                    roto.checkOpenUSDToolsForRetarget()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }

                Text(openUSDRetargetToolsText)
                    .font(.caption2)
                    .foregroundStyle(roto.openUSDToolStatus?.ready == true ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Bake Rig Animation For Export") {
                    roto.bakeLiveRigAnimationForExport()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(!canBakeRigAnimationForExport)

                Text(roto.bakedRigAnimationStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Export Animated Target USDZ") {
                    roto.exportAnimatedTargetUSDZFromRaySolve()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(!canExportAnimatedTargetUSDZ)

                Button("Reveal Last Export") {
                    roto.revealLastAnimatedUSDZExport()
                    uiStatus = roto.status
                    pipelineRenderToken += 1
                }
                .disabled(roto.lastAnimatedUSDZExportURL == nil)

                Text(usdzRetargetReadinessText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(roto.usdzRetargetStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !hasBakeSourceForCurrentMode {
                    Text(roto.captureMode == .spatialVideo
                        ? "Run spatial Solve Full Animation before baking/exporting."
                        : "Run Solve Full Animation before exporting.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var openUSDRetargetToolsText: String {
        guard let status = roto.openUSDToolStatus else {
            return "Tools not checked."
        }

        if status.ready {
            return "Tools ready: \(status.pythonExecutablePath ?? "OpenUSD Python")"
        }

        return "Tools missing. Python: \(status.pythonOK ? "yes" : "no"), usdzip: \(status.usdzipOK ? "yes" : "no")"
    }

    private var usdzRetargetReadinessText: String {
        var needs: [String] = []

        if !hasBakeSourceForCurrentMode {
            needs.append(roto.captureMode == .spatialVideo
                ? "spatial depth-guided ray-pinned solve"
                : "solved ray IK animation")
        }

        if roto.bakedRigAnimation == nil {
            needs.append("baked rig animation")
        }

        if !needs.isEmpty {
            return "Needs: \(needs.joined(separator: ", "))."
        }

        if roto.sessionPoseSource != .posedArmatureLocalTransforms {
            return "Blocked for skinned USDZ: current pose source is \(roto.sessionPoseSource.rawValue), not posed armature local transforms."
        }

        let frames = roto.bakedRigAnimation?.frames.count
            ?? roto.rayAnimationSolveResult?.frames.count
            ?? roto.normalizedLeftCapture?.frames.count
            ?? 0
        let referenceHeight = roto.referenceRigProfile?.estimatedHeightMeters
            .map { String(format: "%.3f m", $0) }
            ?? "default/reference not selected"
        let targetText = roto.targetCharacterUSDZURL?.lastPathComponent ?? "target chosen during export"
        return "Exports animated target USDZ: \(frames) frames, reference \(referenceHeight), target \(targetText)."
    }

    private var spatialRayPinBakeSourceReady: Bool {
        roto.captureMode == .spatialVideo &&
            roto.solveTargetMode == .spatialDepthGuidedRayPinned &&
            !(roto.normalizedLeftCapture?.frames.isEmpty ?? true) &&
            (
                roto.spatialRayPinDepthMode == .leftEyeRayPinningFallback ||
                    !(roto.jointDepthEvidenceCapture?.frames.isEmpty ?? true)
            )
    }

    private var hasBakeSourceForCurrentMode: Bool {
        roto.rayAnimationSolveResult != nil || spatialRayPinBakeSourceReady
    }

    private var canBakeRigAnimationForExport: Bool {
        roto.skinnedRigSession != nil &&
            roto.currentVideoPlaneSize != nil &&
            hasBakeSourceForCurrentMode
    }

    private var canExportAnimatedTargetUSDZ: Bool {
        roto.bakedRigAnimation != nil &&
            roto.sessionPoseSource == .posedArmatureLocalTransforms
    }

    private var rayRigSolvePanel: some View {
        GroupBox("Reference Rig / Ray Solve") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Debug Position Skeleton", isOn: $roto.showDebugSolvedSkeleton)

                Picker("Mode", selection: $roto.raySolveMode) {
                    ForEach(RotoMotionViewModel.RaySolveMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle("Force Camera-Facing Yaw", isOn: $roto.forceCameraFacingYaw)

                Text("Assume actor faces camera. Prevents back-facing or mirrored yaw solutions.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Depth Calibration: Auto from Hips <-> Spine")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Text("Solve Full Animation slides Hips along the camera ray using the reference rig Hips<->Spine distance.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(roto.depthCalibrationStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Solve Full Animation") {
                    Task {
                        await roto.solveFullAnimationWithCameraRays()
                        uiStatus = roto.status
                        pipelineRenderToken += 1
                    }
                }
                .disabled(
                    roto.currentVideoPlaneSize == nil ||
                    (
                        roto.captureMode == .spatialVideo
                            ? roto.normalizedLeftCapture == nil
                            : roto.normalizedCapture == nil
                    )
                )

                Button("Clear Ray Animation") {
                    roto.rayAnimationSolveResult = nil
                    roto.sessionArmatureSnapshot = nil
                    roto.sessionArmaturePoseBuffer = nil
                    roto.bakedRigAnimation = nil
                    roto.bakedRigAnimationStatus = "Ray animation cleared. Bake rig animation before export."
                    roto.sessionPoseSource = .none
                    roto.sessionPoseStatus = "No session pose source detected."
                    roto.rayAnimationSolveStatus = "Ray animation solve cleared."
                    roto.raySolvedUSDZExportStatus = "No ray solve USDZ exported."
                    roto.usdzRetargetStatus = "No animated target USDZ exported."
                    roto.lastAnimatedUSDZExportURL = nil
                    roto.lastAnimatedUSDZExportFolderURL = nil
                    roto.diagnostics.log(roto.rayAnimationSolveStatus)
                    pipelineRenderToken += 1
                }
                .disabled(roto.rayAnimationSolveResult == nil)

                Text(roto.rayAnimationSolveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var currentRightRawFrame: RawVisionPoseCapture.PoseFrame? {
        nearestRightRawFrame(forTime: currentUIVideoTimeSeconds)
    }

    private var currentRightNormalizedFrame: NormalizedMeshyPoseCapture.Frame? {
        nearestRightNormalizedFrame(forTime: currentUIVideoTimeSeconds)
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

    private func nearestRightRawFrame(forTime time: Double) -> RawVisionPoseCapture.PoseFrame? {
        guard roto.captureMode == .spatialVideo,
              let frames = roto.rawRightVisionCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func nearestRightNormalizedFrame(forTime time: Double) -> NormalizedMeshyPoseCapture.Frame? {
        guard roto.captureMode == .spatialVideo,
              let frames = roto.normalizedRightCapture?.frames,
              !frames.isEmpty else {
            return nil
        }

        return frames.min {
            abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
        }
    }

    private func solveCurrentFrameRays(
        mode: RotoMotionViewModel.RaySolveMode? = nil
    ) {
        if let mode {
            roto.raySolveMode = mode
        }

        guard let planeSize = roto.currentVideoPlaneSize else {
            roto.raySolveStatus = "No video plane size yet."
            roto.diagnostics.log(roto.raySolveStatus)
            pipelineRenderToken += 1
            return
        }

        guard currentNormalizedFrame != nil else {
            roto.raySolveStatus = "Cannot solve rays: no normalized Meshy24 frame."
            roto.diagnostics.log(roto.raySolveStatus)
            pipelineRenderToken += 1
            return
        }

        roto.currentFrameIndex = uiCurrentFrameIndex
        roto.currentTimeSeconds = currentUIVideoTimeSeconds
        roto.solveCurrentFrameRays(videoPlaneSize: planeSize)
        uiStatus = roto.status
        pipelineRenderToken += 1
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
        roto.captureMode = .monocularVideo
        roto.clearSpatialVideoState()
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
        roto.currentRaySolveResult = nil
        roto.rayAnimationSolveResult = nil
        roto.sessionArmatureSnapshot = nil
        roto.sessionArmaturePoseBuffer = nil
        roto.resetRotationAuthoringForNewSession()
        roto.bakedRigAnimation = nil
        roto.bakedRigAnimationStatus = "Video changed. Bake rig animation before export."
        roto.sessionPoseSource = .none
        roto.sessionPoseStatus = "No session pose source detected."
        roto.currentVideoPlaneSize = nil
        roto.raySolveStatus = "Ray solve not run."
        roto.rayAnimationSolveStatus = "Ray animation solve not run."
        roto.raySolvedUSDZExportStatus = "No ray solve USDZ exported."
        roto.usdzRetargetStatus = "No animated target USDZ exported."
        roto.lastAnimatedUSDZExportURL = nil
        roto.lastAnimatedUSDZExportFolderURL = nil
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

    private func openSpatialVideoDirectlyInContentView() {
        print("[RotoMotion UI] Open Spatial Video requested.")

        guard let url = FilePanelHelpers.openVideoURL() else {
            uiStatus = "Open spatial video canceled."
            roto.status = uiStatus
            roto.diagnostics.log("Open Spatial Video canceled by user.")
            return
        }

        releaseUIVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()
        uiSecurityScopedURL = url
        uiSecurityScopedAccessActive = didAccess
        uiVideoURL = url

        uiStatus = "Decoding spatial video \(url.lastPathComponent)..."
        uiDecodedFrames = []
        uiCurrentImage = nil
        uiCurrentFrameIndex = 0
        uiRenderToken += 1
        playbackStartHostTime = nil
        playbackStartVideoTime = 0
        pipelineRenderToken += 1

        installUIAudioPlayer(for: url)

        Task {
            await roto.loadSpatialVideo(url: url)

            await MainActor.run {
                let frames = roto.decodedFrames
                uiDecodedFrames = frames
                uiCurrentFrameIndex = 0
                uiCurrentImage = frames.first?.image
                uiRenderToken += 1
                pipelineRenderToken += 1
                uiStatus = roto.status

                roto.diagnostics.log("""
                Spatial video assigned to active UI:
                  left viewport frames: \(frames.count)
                  firstTime: \(frames.first?.timeSeconds ?? -1)
                  lastTime: \(frames.last?.timeSeconds ?? -1)
                  currentImage: \(uiCurrentImage != nil)
                """)
            }
        }
    }

    private func openRotoMotionSessionFromContentView() {
        roto.openRotoMotionSession()
        uiStatus = roto.status
        pipelineRenderToken += 1

        guard roto.sessionFileStatus.hasPrefix("Loaded RotoMotion session") else {
            return
        }

        guard let url = roto.videoURL,
              FileManager.default.fileExists(atPath: url.path) else {
            uiStatus = "Session loaded. Saved video path is missing."
            roto.diagnostics.log(uiStatus)
            return
        }

        loadSessionVideoFramesInContentView(
            url: url,
            restoredFrameIndex: roto.currentFrameIndex
        )
    }

    private func loadSessionVideoFramesInContentView(
        url: URL,
        restoredFrameIndex: Int
    ) {
        releaseUIVideoAccess()

        let didAccess = url.startAccessingSecurityScopedResource()
        uiSecurityScopedURL = url
        uiSecurityScopedAccessActive = didAccess
        uiVideoURL = url

        uiStatus = "Decoding session video \(url.lastPathComponent)..."
        uiDecodedFrames = []
        uiCurrentImage = nil
        uiCurrentFrameIndex = 0
        uiRenderToken += 1
        playbackStartHostTime = nil
        playbackStartVideoTime = 0
        pipelineRenderToken += 1

        roto.videoURL = url
        roto.lastLoadedVideoURL = url
        if roto.outputDirectoryURL == nil {
            roto.outputDirectoryURL = RotoMotionProjectStore.defaultOutputDirectory(for: url)
        }
        roto.decodedFrames = []
        roto.currentVideoFrameImage = nil
        roto.maxFrameIndex = 0
        roto.videoPlaybackStatus = "Decoding session video frames..."
        roto.status = uiStatus
        roto.diagnostics.log("""
        Session video restore:
          path: \(url.path)
          securityScoped: \(didAccess)
          restoredFrameIndex: \(restoredFrameIndex)
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
                let clamped = frames.isEmpty
                    ? 0
                    : max(0, min(frames.count - 1, restoredFrameIndex))
                let restoredFrame = frames.indices.contains(clamped) ? frames[clamped] : nil

                uiDecodedFrames = frames
                uiCurrentFrameIndex = clamped
                uiCurrentImage = restoredFrame?.image
                uiRenderToken += 1
                pipelineRenderToken += 1

                let fpsEstimate = RotoVideoFrameCache.estimatedFPS(frames: frames)
                uiStatus = frames.isEmpty ? cache.status : "Session video frames ready: \(frames.count)"

                roto.decodedFrames = frames
                roto.maxFrameIndex = max(0, frames.count - 1)
                roto.currentFrameIndex = clamped
                roto.currentTimeSeconds = restoredFrame?.timeSeconds ?? roto.currentTimeSeconds
                roto.currentVideoFrameImage = restoredFrame?.image
                roto.imageRenderToken += 1
                roto.videoPlaybackStatus = uiStatus
                roto.status = "Session video ready: \(frames.count) source frames"
                roto.diagnostics.log("""
                Session video decode assigned to active UI:
                  decodedFrames: \(frames.count)
                  estimatedFPS: \(String(format: "%.3f", fpsEstimate))
                  restoredFrame: \(clamped)
                  restoredTime: \(restoredFrame?.timeSeconds ?? -1)
                  currentImage: \(uiCurrentImage != nil)
                """)
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

        if roto.currentRaySolveResult?.frameIndex != clamped {
            roto.currentRaySolveResult = nil
            roto.raySolveStatus = "Ray solve not run for current frame."
        }

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

}

struct ScrollWheelDegreeField: View {
    let label: String
    @Binding var value: Double
    let onValueChanged: (Double) -> Void

    var stepDegrees: Double = 1.0
    var scrollUnitsPerStep: CGFloat = 10.0

    @State private var isHovered = false
    @State private var scrollAccumulator: CGFloat = 0
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .monospaced()
                .frame(width: 16, alignment: .leading)
                .foregroundStyle(.secondary)

            TextField(
                label,
                value: Binding(
                    get: { value },
                    set: { newValue in
                        value = newValue
                        onValueChanged(newValue)
                    }
                ),
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 82)

            Text("°")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering

            if hovering {
                installScrollMonitor()
            } else {
                removeScrollMonitor()
                scrollAccumulator = 0
            }
        }
        .onDisappear {
            removeScrollMonitor()
            scrollAccumulator = 0
        }
    }

    private func installScrollMonitor() {
        guard monitor == nil else {
            return
        }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { event in
            guard isHovered else {
                return event
            }

            handleScroll(event)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        let dominantDelta: CGFloat

        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            dominantDelta = event.scrollingDeltaX
        } else {
            dominantDelta = event.scrollingDeltaY
        }

        guard abs(dominantDelta) > 0.0001 else {
            return
        }

        scrollAccumulator += dominantDelta

        let rawSteps = scrollAccumulator / scrollUnitsPerStep
        let wholeSteps = Int(rawSteps.rounded(.towardZero))

        guard wholeSteps != 0 else {
            return
        }

        scrollAccumulator -= CGFloat(wholeSteps) * scrollUnitsPerStep

        let newValue = value + Double(wholeSteps) * stepDegrees
        value = newValue
        onValueChanged(newValue)
    }
}

struct RotationKeyTimelineMarkers: View {
    let frameCount: Int
    let keyframes: [JointRotationOverrideLayer.Keyframe]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)

                ForEach(keyframes) { key in
                    let denom = CGFloat(max(frameCount - 1, 1))
                    let x = CGFloat(key.frameIndex) / denom * geo.size.width

                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 3, height: 16)
                        .shadow(color: .yellow, radius: 2)
                        .offset(x: x)
                }
            }
        }
    }
}
