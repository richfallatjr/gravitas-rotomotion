import Foundation
import CoreGraphics
import SceneKit
import simd

struct JointRay {
    let jointName: String
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>

    func point(at t: Float) -> SIMD3<Float> {
        origin + direction * t
    }
}

struct CurvePinnedSettings {
    var limbPinWiggle: Float = 0.02
    var limbPinPull: Float = 0.65

    var iterations: Int = 8

    static let `default` = CurvePinnedSettings()
}

enum JointRayBuilder {
    static func buildRays(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float
    ) -> [String: JointRay] {
        var rays: [String: JointRay] = [:]

        for (jointName, joint) in normalizedFrame.joints {
            guard !joint.missing else {
                continue
            }

            let planePoint = SIMD3<Float>(
                (Float(joint.x) - 0.5) * Float(videoPlaneSize.width),
                (Float(joint.y) - 0.5) * Float(videoPlaneSize.height),
                videoPlaneZ
            )

            let direction = normalizeSafe(planePoint - cameraOrigin)

            rays[jointName] = JointRay(
                jointName: jointName,
                origin: cameraOrigin,
                direction: direction
            )
        }

        return rays
    }

    private static func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.000001 else {
            return SIMD3<Float>(0, 0, -1)
        }

        return v / len
    }
}

struct RayPinDepthGuidance {
    let jointName: String
    let disparityDepthMeters: Float?
    let stereoJointDepthMeters: Float?
    let confidence: Float
    let accepted: Bool
    let source: String
    let status: String
}

enum RayPinDepthGuidanceBuilder {
    static func build(
        evidenceFrame: JointDepthEvidenceCapture.Frame?
    ) -> [String: RayPinDepthGuidance] {
        guard let evidenceFrame else {
            return [:]
        }

        var out: [String: RayPinDepthGuidance] = [:]

        for (jointName, evidence) in evidenceFrame.joints {
            let accepted = evidence.disparityDepthMeters != nil &&
                evidence.passesDepthValidation

            out[jointName] = RayPinDepthGuidance(
                jointName: jointName,
                disparityDepthMeters: evidence.disparityDepthMeters.map(Float.init),
                stereoJointDepthMeters: evidence.stereoJointDepthMeters.map(Float.init),
                confidence: Float(evidence.disparityConfidence),
                accepted: accepted,
                source: evidence.winningCandidateSource ?? "none",
                status: evidence.status + "|winner=\(evidence.winningCandidateSource ?? "nil")"
            )
        }

        return out
    }
}

private struct DisparityDepthRemap {
    let valid: Bool

    /// sceneDepth = scale * disparityDepthMeters + offset
    let scale: Float
    let offset: Float

    let anchorCount: Int
    let boneResidualMean: Float
    let boneResidualMax: Float
    let bodyMedianDepthMeters: Float
    let bodyDepthMinMeters: Float
    let bodyDepthMaxMeters: Float
    let medianResidual: Float

    static let invalid = DisparityDepthRemap(
        valid: false,
        scale: 1,
        offset: 0,
        anchorCount: 0,
        boneResidualMean: 0,
        boneResidualMax: 0,
        bodyMedianDepthMeters: 0,
        bodyDepthMinMeters: 0,
        bodyDepthMaxMeters: 0,
        medianResidual: 0
    )
}

private struct DisparityDepthFitAdjustment {
    let valid: Bool
    let depthZoom: Float
    let depthOffset: Float
    let pivotSceneDepth: Float
    let score: Float
    let boneResidualMean: Float
    let boneResidualMax: Float
    let targetDistanceMean: Float
    let exactTargetCount: Int

    static let identity = DisparityDepthFitAdjustment(
        valid: true,
        depthZoom: 1,
        depthOffset: 0,
        pivotSceneDepth: 0,
        score: 0,
        boneResidualMean: 0,
        boneResidualMax: 0,
        targetDistanceMean: 0,
        exactTargetCount: 0
    )
}

private struct ExactRayDepthTarget {
    let jointName: String
    let point: SIMD3<Float>
    let depthMeters: Float
    let source: String
    let confidence: Float
}

struct DepthGuidedRayPinSolveStats {
    let frameIndex: Int
    let depthMode: SpatialRayPinDepthMode
    let depthEvidenceJoints: Int
    let exactDepthTargets: Int
    let depthCalibrationValid: Bool
    let affineScale: Float
    let affineOffset: Float
    let affineAnchorCount: Int
    let affineMedianResidual: Float
    let autoDepthZoom: Float
    let autoDepthOffset: Float
    let finalDepthZoom: Float
    let finalDepthOffset: Float
    let depthFitZoom: Float
    let depthFitOffset: Float
    let depthFitPivotSceneDepth: Float
    let depthFitScore: Float
    let depthFitBoneResidualMean: Float
    let depthFitBoneResidualMax: Float
    let depthFitTargetDistanceMean: Float
    let avgRayDistance: Float
    let worstJoint: String
    let worstRayDistance: Float
}

private struct DriverPoseSnapshot {
    let displayRootTransform: simd_float4x4
    let boneTransforms: [String: simd_float4x4]
}

private struct ExactDepthSolveEvaluation {
    let score: Float
    let avgExactResidual: Float
    let maxExactResidual: Float
    let avgRayDistance: Float
}

private enum DisparityDepthRemapSolver {
    static func fit(
        session: SkinnedRigSession,
        depthGuidance: [String: RayPinDepthGuidance]
    ) -> DisparityDepthRemap {
        let anchors = [
            "Hips",
            "Spine02",
            "Spine01",
            "Spine",
            "neck",
            "Head",
            "LeftShoulder",
            "RightShoulder",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var samples: [(depthMeters: Float, sceneDepth: Float, joint: String)] = []

        for jointName in anchors {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let guidance = depthGuidance[jointName],
                  guidance.accepted,
                  let depth = guidance.disparityDepthMeters,
                  depth.isFinite,
                  depth > 0 else {
                continue
            }

            let sceneDepth = max(-bone.simdWorldPosition.z, 0.0001)

            guard sceneDepth.isFinite else {
                continue
            }

            samples.append((depth, sceneDepth, jointName))
        }

        guard samples.count >= 2 else {
            return .invalid
        }

        var slopes: [Float] = []

        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let depthDelta = samples[j].depthMeters - samples[i].depthMeters
                let sceneDelta = samples[j].sceneDepth - samples[i].sceneDepth

                guard abs(depthDelta) > 0.05 else {
                    continue
                }

                let slope = sceneDelta / depthDelta

                if slope.isFinite,
                   slope > 0 {
                    slopes.append(slope)
                }
            }
        }

        let scale: Float

        if slopes.isEmpty {
            var ratios = samples
                .map { $0.sceneDepth / max($0.depthMeters, 0.001) }
                .filter { $0.isFinite && $0 > 0 }

            guard !ratios.isEmpty else {
                return .invalid
            }

            ratios.sort()
            scale = ratios[ratios.count / 2]
        } else {
            slopes.sort()
            scale = slopes[slopes.count / 2]
        }

        var offsets = samples
            .map { $0.sceneDepth - scale * $0.depthMeters }
            .filter { $0.isFinite }

        guard !offsets.isEmpty else {
            return .invalid
        }

        offsets.sort()
        let offset = offsets[offsets.count / 2]

        var residuals = samples
            .map { abs($0.sceneDepth - (scale * $0.depthMeters + offset)) }
            .filter { $0.isFinite }

        residuals.sort()
        let medianResidual = residuals.isEmpty ? 0 : residuals[residuals.count / 2]

        print("""
        [DepthGuidedRayPinning] affine depth calibration
          valid: true
          anchors: \(samples.count)
          scale: \(scale)
          offset: \(offset)
          medianResidual: \(medianResidual)
          samples:
          \(samples.map {
              "\($0.joint): disparityDepth=\(String(format: "%.3f", $0.depthMeters)) sceneDepth=\(String(format: "%.3f", $0.sceneDepth)) predicted=\(String(format: "%.3f", scale * $0.depthMeters + offset))"
          }.joined(separator: "\n"))
        """)

        var bodyDepths = samples.map { $0.depthMeters }
        bodyDepths.sort()

        return DisparityDepthRemap(
            valid: true,
            scale: scale,
            offset: offset,
            anchorCount: samples.count,
            boneResidualMean: medianResidual,
            boneResidualMax: residuals.last ?? 0,
            bodyMedianDepthMeters: bodyDepths[bodyDepths.count / 2],
            bodyDepthMinMeters: bodyDepths.first ?? 0,
            bodyDepthMaxMeters: bodyDepths.last ?? 0,
            medianResidual: medianResidual
        )
    }
}

struct RayPinStereoEnvelope {
    let jointName: String
    let valid: Bool
    let status: String
}

enum RayPinStereoEnvelopeBuilder {
    static func build(
        leftFrame: NormalizedMeshyPoseCapture.Frame,
        rightFrame: NormalizedMeshyPoseCapture.Frame?
    ) -> [String: RayPinStereoEnvelope] {
        var out: [String: RayPinStereoEnvelope] = [:]

        for jointName in CanonicalRig.jointNames {
            guard let left = leftFrame.joints[jointName],
                  !left.missing else {
                continue
            }

            guard let right = rightFrame?.joints[jointName],
                  !right.missing else {
                out[jointName] = RayPinStereoEnvelope(
                    jointName: jointName,
                    valid: true,
                    status: "left_only"
                )
                continue
            }

            let verticalMismatch = abs(left.y - right.y)
            let valid = verticalMismatch < 0.08

            out[jointName] = RayPinStereoEnvelope(
                jointName: jointName,
                valid: valid,
                status: valid ? "stereo_envelope_valid" : "stereo_envelope_vertical_mismatch"
            )
        }

        return out
    }
}

enum SkinnedRigRotomationDriver {
    private static let depthFitCalibrationJoints: [String] = [
        "Hips",
        "Spine02",
        "Spine01",
        "Spine",
        "neck",
        "Head",
        "LeftShoulder",
        "RightShoulder",
        "LeftUpLeg",
        "RightUpLeg"
    ]

    private static let depthFitCalibrationBones: [(String, String, Float)] = [
        ("Hips", "Spine02", 2.0),
        ("Spine02", "Spine01", 2.0),
        ("Spine01", "Spine", 2.0),
        ("Spine", "neck", 2.0),
        ("neck", "Head", 2.0),
        ("LeftShoulder", "RightShoulder", 2.0),
        ("Hips", "LeftUpLeg", 1.5),
        ("Hips", "RightUpLeg", 1.5),
        ("LeftArm", "LeftForeArm", 0.75),
        ("LeftForeArm", "LeftHand", 0.75),
        ("RightArm", "RightForeArm", 0.75),
        ("RightForeArm", "RightHand", 0.75),
        ("LeftLeg", "LeftFoot", 0.75),
        ("RightLeg", "RightFoot", 0.75)
    ]

    static let armChains: [[String]] = [
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"]
    ]

    static let torsoChain: [String] = [
        "Hips",
        "Spine",
        "neck",
        "Head",
        "headfront"
    ]

    static let legSides = [
        "Left",
        "Right"
    ]

    static let solveChains: [[String]] = [
        ["neck", "Head", "headfront"],
        ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
        ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
        ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
        ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
    ]

    static func rotomateFrameWithCurvePins(
        _ frame: RotoRayAnimationSolveResult.Frame,
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float,
        settings: CurvePinnedSettings = .default
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)

        let rays = JointRayBuilder.buildRays(
            normalizedFrame: normalizedFrame,
            cameraOrigin: cameraOrigin,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )

        if frame.frameIndex == 0 {
            print(
                """
                [CurvePinnedRotomation] Ordered ray-pinned solve:
                  initial Hips-Spine fit reused: false
                  Hips ray pinned: false
                  Spine static locked: false
                  pelvis driver: LeftUpLeg + RightUpLeg rays
                  displayRoot moved by solve: true
                """
            )
        }

        solvePelvisFromUpperLegRays(
            session: session,
            rays: rays
        )

        solvePinnedJointSequence(
            ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["Hips", "Spine", "neck", "Head", "headfront"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
            rays: rays,
            session: session
        )

        solvePinnedJointSequence(
            ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
            rays: rays,
            session: session
        )

        SCNTransaction.commit()

        logPinnedFitError(
            session: session,
            rays: rays,
            frameIndex: frame.frameIndex
        )
    }

    @discardableResult
    static func rotomateFrameWithDepthGuidedRayPins(
        normalizedFrame: NormalizedMeshyPoseCapture.Frame,
        jointDepthEvidenceFrame: JointDepthEvidenceCapture.Frame?,
        depthMode: SpatialRayPinDepthMode,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>,
        videoPlaneSize: CGSize,
        videoPlaneZ: Float,
        depthFitSettings: SpatialRayPinDepthFitSettings = .default,
        autoDepthFitEnabled: Bool = true,
        manualDepthZoom: Float = 1,
        manualDepthOffset: Float = 0,
        iterations: Int = 8
    ) -> DepthGuidedRayPinSolveStats {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)

        let rays = JointRayBuilder.buildRays(
            normalizedFrame: normalizedFrame,
            cameraOrigin: cameraOrigin,
            videoPlaneSize: videoPlaneSize,
            videoPlaneZ: videoPlaneZ
        )
        let depthGuidance: [String: RayPinDepthGuidance]

        switch depthMode {
        case .disparityDepthGuided:
            depthGuidance = RayPinDepthGuidanceBuilder.build(
                evidenceFrame: jointDepthEvidenceFrame
            )

        case .leftEyeRayPinningFallback:
            depthGuidance = [:]
        }

        let legacyIterations = depthMode == .disparityDepthGuided ? 2 : iterations

        runLegacyRayPinningPass(
            session: session,
            rays: rays,
            iterations: legacyIterations
        )

        var remap = DisparityDepthRemap.invalid
        var autoDepthFitAdjustment = DisparityDepthFitAdjustment.identity
        var depthFitAdjustment = DisparityDepthFitAdjustment.identity

        if depthMode == .disparityDepthGuided {
            var bestSnapshot = makePoseSnapshot(session)
            var bestRemap = remap
            var bestAutoAdjustment = autoDepthFitAdjustment
            var bestAdjustment = depthFitAdjustment
            var bestScore = Float.greatestFiniteMagnitude
            var previousScore = Float.greatestFiniteMagnitude
            var acceptedExactPass = false
            let maxPasses = max(depthFitSettings.maxRefinementPasses, 1)

            for pass in 0..<maxPasses {
                remap = DisparityDepthRemapSolver.fit(
                    session: session,
                    depthGuidance: depthGuidance
                )

                guard isReasonableRemap(remap) else {
                    print("""
                    [DepthGuidedRayPinning] exact depth pass skipped
                      reason: unreasonable disparity remap
                      valid: \(remap.valid)
                      scale: \(remap.scale)
                      offset: \(remap.offset)
                      anchors: \(remap.anchorCount)
                      medianResidual: \(remap.medianResidual)
                    """)
                    break
                }

                autoDepthFitAdjustment = solveDepthFitAdjustment(
                    session: session,
                    rays: rays,
                    depthGuidance: depthGuidance,
                    remap: remap,
                    settings: depthFitSettings,
                    manualZoom: nil,
                    manualOffset: nil
                )

                depthFitAdjustment = composeDepthFitAdjustment(
                    autoAdjustment: autoDepthFitAdjustment,
                    autoDepthFitEnabled: autoDepthFitEnabled,
                    manualDepthZoom: manualDepthZoom,
                    manualDepthOffset: manualDepthOffset
                )

                depthFitAdjustment = scoreDepthFitAdjustment(
                    depthFitAdjustment,
                    session: session,
                    rays: rays,
                    depthGuidance: depthGuidance,
                    remap: remap,
                    settings: depthFitSettings
                )

                guard depthFitAdjustment.valid else {
                    print("""
                    [DepthGuidedRayPinning] exact depth pass skipped
                      reason: invalid depth fit adjustment
                      remapValid: \(remap.valid)
                      autoExactTargetCount: \(autoDepthFitAdjustment.exactTargetCount)
                      finalExactTargetCount: \(depthFitAdjustment.exactTargetCount)
                    """)
                    break
                }

                runExactDepthPass(
                    rays: rays,
                    depthGuidance: depthGuidance,
                    remap: remap,
                    adjustment: depthFitAdjustment,
                    session: session,
                    iterations: iterations
                )

                let eval = evaluateExactDepthSolve(
                    session: session,
                    rays: rays,
                    depthGuidance: depthGuidance,
                    remap: remap,
                    adjustment: depthFitAdjustment
                )

                if normalizedFrame.frameIndex == 0 || normalizedFrame.frameIndex % 30 == 0 {
                    print("""
                    [DepthGuidedRayPinning] refinement pass
                      frame: \(normalizedFrame.frameIndex)
                      pass: \(pass)
                      autoDepthZoom: \(autoDepthFitAdjustment.depthZoom)
                      autoDepthOffset: \(autoDepthFitAdjustment.depthOffset)
                      manualDepthZoom: \(manualDepthZoom)
                      manualDepthOffset: \(manualDepthOffset)
                      depthZoom: \(depthFitAdjustment.depthZoom)
                      depthOffset: \(depthFitAdjustment.depthOffset)
                      fitScore: \(depthFitAdjustment.score)
                      evalScore: \(eval.score)
                      avgExactResidual: \(eval.avgExactResidual)
                      maxExactResidual: \(eval.maxExactResidual)
                      avgRayDistance: \(eval.avgRayDistance)
                      boneResidualMean: \(depthFitAdjustment.boneResidualMean)
                      targetDistanceMean: \(depthFitAdjustment.targetDistanceMean)
                    """)
                }

                if eval.score < bestScore {
                    bestScore = eval.score
                    bestSnapshot = makePoseSnapshot(session)
                    bestRemap = remap
                    bestAutoAdjustment = autoDepthFitAdjustment
                    bestAdjustment = depthFitAdjustment
                    acceptedExactPass = true
                }

                if abs(previousScore - eval.score) < depthFitSettings.minImprovement {
                    break
                }

                previousScore = eval.score
            }

            if acceptedExactPass {
                restorePoseSnapshot(bestSnapshot, session: session)
                remap = bestRemap
                autoDepthFitAdjustment = bestAutoAdjustment
                depthFitAdjustment = bestAdjustment
            }
        }

        SCNTransaction.commit()

        let stats = makeDepthGuidedRayPinSolveStats(
            session: session,
            rays: rays,
            depthGuidance: depthGuidance,
            remap: remap,
            autoAdjustment: autoDepthFitAdjustment,
            adjustment: depthFitAdjustment,
            frameIndex: normalizedFrame.frameIndex,
            depthMode: depthMode
        )

        logExactDepthRayPinFit(
            stats: stats,
            session: session,
            rays: rays,
            depthGuidance: depthGuidance,
            remap: remap,
            autoAdjustment: autoDepthFitAdjustment,
            adjustment: depthFitAdjustment,
            autoDepthFitEnabled: autoDepthFitEnabled,
            manualDepthZoom: manualDepthZoom,
            manualDepthOffset: manualDepthOffset,
            depthMode: depthMode
        )

        return stats
    }

    static func rotomateFrame(
        _ frame: RotoRayAnimationSolveResult.Frame,
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        iterations: Int = 12
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetToRest(session: session)
        lockBase(
            session: session,
            targets: frame.jointPositions
        )

        for _ in 0..<iterations {
            for chain in solveChains {
                solveChainToPositions(
                    chain,
                    targets: frame.jointPositions,
                    session: session,
                    cameraOrigin: cameraOrigin
                )
            }
        }

        SCNTransaction.commit()

        logFitError(
            frame: frame,
            session: session
        )
    }

    static func resetToRest(session: SkinnedRigSession) {
        resetBonesToRestOnly(session: session)
    }

    private static func resetBonesToRestOnly(session: SkinnedRigSession) {
        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName] else {
                continue
            }

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation
            bone.simdScale = restScale
        }
    }

    private static func solvePelvisFromUpperLegRays(
        session: SkinnedRigSession,
        rays: [String: JointRay]
    ) {
        guard let leftHipNode = session.bonesByCanonicalName["LeftUpLeg"],
              let rightHipNode = session.bonesByCanonicalName["RightUpLeg"],
              let hipsNode = session.bonesByCanonicalName["Hips"],
              let leftRay = rays["LeftUpLeg"],
              let rightRay = rays["RightUpLeg"] else {
            return
        }

        let leftCurrent = leftHipNode.simdWorldPosition
        let rightCurrent = rightHipNode.simdWorldPosition

        let leftTarget = closestPointOnRay(
            ray: leftRay,
            to: leftCurrent
        )
        let rightTarget = closestPointOnRay(
            ray: rightRay,
            to: rightCurrent
        )

        let averageDelta = ((leftTarget - leftCurrent) + (rightTarget - rightCurrent)) * 0.5
        session.displayRootNode.simdPosition += averageDelta

        let currentWidth = rightHipNode.simdWorldPosition - leftHipNode.simdWorldPosition
        let targetWidth = rightTarget - leftTarget

        guard simd_length(currentWidth) > 0.0001,
              simd_length(targetWidth) > 0.0001 else {
            return
        }

        let deltaWorld = simd_quatf(
            from: simd_normalize(currentWidth),
            to: simd_normalize(targetWidth)
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: hipsNode
        )
    }

    private static func placePelvisFromUpperLegRayPins(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance]
    ) {
        let driverJoints = [
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var deltas: [SIMD3<Float>] = []

        for jointName in driverJoints {
            guard depthGuidance[jointName]?.accepted != false,
                  let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName] else {
                continue
            }

            let current = bone.simdWorldPosition
            let target = closestPointOnRay(
                ray: ray,
                to: current
            )

            deltas.append(target - current)
        }

        guard !deltas.isEmpty else {
            return
        }

        let average = deltas.reduce(SIMD3<Float>(0, 0, 0), +) / Float(deltas.count)
        session.displayRootNode.simdPosition += average
    }

    private static func runLegacyRayPinningPass(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        iterations: Int
    ) {
        placePelvisFromUpperLegRayPins(
            session: session,
            rays: rays,
            depthGuidance: [:]
        )

        for _ in 0..<iterations {
            solveLegacyRayPinChain(
                ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
                rays: rays,
                session: session
            )
            solveLegacyRayPinChain(
                ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
                rays: rays,
                session: session
            )
            solveLegacyRayPinChain(
                ["Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "headfront"],
                rays: rays,
                session: session
            )
            solveLegacyRayPinChain(
                ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
                rays: rays,
                session: session
            )
            solveLegacyRayPinChain(
                ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
                rays: rays,
                session: session
            )
        }
    }

    private static func runExactDepthPass(
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment,
        session: SkinnedRigSession,
        iterations: Int
    ) {
        placePelvisFromExactRayDepthTargets(
            session: session,
            rays: rays,
            depthGuidance: depthGuidance,
            remap: remap,
            adjustment: adjustment
        )

        for _ in 0..<iterations {
            solveExactDepthRayChain(
                ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                adjustment: adjustment,
                session: session
            )
            solveExactDepthRayChain(
                ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                adjustment: adjustment,
                session: session
            )
            solveExactDepthRayChain(
                ["Hips", "Spine02", "Spine01", "Spine", "neck", "Head", "headfront"],
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                adjustment: adjustment,
                session: session
            )
            solveExactDepthRayChain(
                ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                adjustment: adjustment,
                session: session
            )
            solveExactDepthRayChain(
                ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                adjustment: adjustment,
                session: session
            )
        }
    }

    private static func solveDepthFitAdjustment(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        settings: SpatialRayPinDepthFitSettings,
        manualZoom: Float?,
        manualOffset: Float?
    ) -> DisparityDepthFitAdjustment {
        guard remap.valid else {
            return .identity
        }

        let pivotSceneDepth = medianLegacySceneDepth(
            session: session,
            jointNames: depthFitCalibrationJoints
        )

        if let manualZoom,
           let manualOffset {
            let candidate = DisparityDepthFitAdjustment(
                valid: true,
                depthZoom: manualZoom,
                depthOffset: manualOffset,
                pivotSceneDepth: pivotSceneDepth,
                score: 0,
                boneResidualMean: 0,
                boneResidualMax: 0,
                targetDistanceMean: 0,
                exactTargetCount: 0
            )

            return scoreDepthFitAdjustment(
                candidate,
                session: session,
                rays: rays,
                depthGuidance: depthGuidance,
                remap: remap,
                settings: settings
            )
        }

        var best: DisparityDepthFitAdjustment?
        let zoomSteps = max(settings.depthZoomSteps, 1)
        let offsetSteps = max(settings.depthOffsetSteps, 1)

        for zoomIndex in 0..<zoomSteps {
            let zoomT = zoomSteps == 1
                ? Float(0.5)
                : Float(zoomIndex) / Float(zoomSteps - 1)
            let depthZoom = settings.minDepthZoom +
                zoomT * (settings.maxDepthZoom - settings.minDepthZoom)

            for offsetIndex in 0..<offsetSteps {
                let offsetT = offsetSteps == 1
                    ? Float(0.5)
                    : Float(offsetIndex) / Float(offsetSteps - 1)
                let depthOffset = -settings.maxDepthOffsetSceneUnits +
                    offsetT * settings.maxDepthOffsetSceneUnits * 2
                let candidate = DisparityDepthFitAdjustment(
                    valid: true,
                    depthZoom: depthZoom,
                    depthOffset: depthOffset,
                    pivotSceneDepth: pivotSceneDepth,
                    score: 0,
                    boneResidualMean: 0,
                    boneResidualMax: 0,
                    targetDistanceMean: 0,
                    exactTargetCount: 0
                )
                let scored = scoreDepthFitAdjustment(
                    candidate,
                    session: session,
                    rays: rays,
                    depthGuidance: depthGuidance,
                    remap: remap,
                    settings: settings
                )

                if best == nil || scored.score < best!.score {
                    best = scored
                }
            }
        }

        return best ?? .identity
    }

    private static func scoreDepthFitAdjustment(
        _ adjustment: DisparityDepthFitAdjustment,
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        settings: SpatialRayPinDepthFitSettings
    ) -> DisparityDepthFitAdjustment {
        var scoredJoints = Set(depthFitCalibrationJoints)

        for (a, b, _) in depthFitCalibrationBones {
            scoredJoints.insert(a)
            scoredJoints.insert(b)
        }

        var targetByJoint: [String: SIMD3<Float>] = [:]

        for jointName in scoredJoints {
            guard let ray = rays[jointName],
                  let guidance = depthGuidance[jointName],
                  let target = exactRayDepthPoint(
                    ray: ray,
                    guidance: guidance,
                    remap: remap,
                    adjustment: adjustment
                  ) else {
                continue
            }

            targetByJoint[jointName] = target
        }

        guard !targetByJoint.isEmpty else {
            return DisparityDepthFitAdjustment(
                valid: false,
                depthZoom: adjustment.depthZoom,
                depthOffset: adjustment.depthOffset,
                pivotSceneDepth: adjustment.pivotSceneDepth,
                score: Float.greatestFiniteMagnitude,
                boneResidualMean: Float.greatestFiniteMagnitude,
                boneResidualMax: Float.greatestFiniteMagnitude,
                targetDistanceMean: Float.greatestFiniteMagnitude,
                exactTargetCount: 0
            )
        }

        var weightedResidualSum: Float = 0
        var weightSum: Float = 0
        var residualMax: Float = 0

        for (a, b, weight) in depthFitCalibrationBones {
            guard let targetA = targetByJoint[a],
                  let targetB = targetByJoint[b],
                  let boneA = session.bonesByCanonicalName[a],
                  let boneB = session.bonesByCanonicalName[b] else {
                continue
            }

            let currentLength = simd_length(boneB.simdWorldPosition - boneA.simdWorldPosition)
            let targetLength = simd_length(targetB - targetA)
            let residual = abs(targetLength - currentLength)

            guard residual.isFinite else {
                continue
            }

            weightedResidualSum += residual * weight
            weightSum += weight
            residualMax = max(residualMax, residual)
        }

        let boneResidualMean = weightSum > 0
            ? weightedResidualSum / weightSum
            : Float.greatestFiniteMagnitude
        var targetDistances: [Float] = []

        for (jointName, target) in targetByJoint {
            if let bone = session.bonesByCanonicalName[jointName] {
                let distance = simd_length(target - bone.simdWorldPosition)

                if distance.isFinite {
                    targetDistances.append(distance)
                }
            }
        }

        let targetDistanceMean = targetDistances.isEmpty
            ? 0
            : targetDistances.reduce(0, +) / Float(targetDistances.count)
        let score = settings.boneLengthWeight * boneResidualMean +
            settings.legacyPoseDistanceWeight * targetDistanceMean

        return DisparityDepthFitAdjustment(
            valid: score.isFinite,
            depthZoom: adjustment.depthZoom,
            depthOffset: adjustment.depthOffset,
            pivotSceneDepth: adjustment.pivotSceneDepth,
            score: score,
            boneResidualMean: boneResidualMean,
            boneResidualMax: residualMax,
            targetDistanceMean: targetDistanceMean,
            exactTargetCount: targetByJoint.count
        )
    }

    private static func composeDepthFitAdjustment(
        autoAdjustment: DisparityDepthFitAdjustment,
        autoDepthFitEnabled: Bool,
        manualDepthZoom: Float,
        manualDepthOffset: Float
    ) -> DisparityDepthFitAdjustment {
        let clampedManualZoom = max(0.25, min(3.0, manualDepthZoom))
        let clampedManualOffset = max(-8.0, min(8.0, manualDepthOffset))
        let baseZoom: Float
        let baseOffset: Float
        let basePivot = autoAdjustment.pivotSceneDepth

        if autoDepthFitEnabled {
            baseZoom = autoAdjustment.depthZoom
            baseOffset = autoAdjustment.depthOffset
        } else {
            baseZoom = 1
            baseOffset = 0
        }

        return DisparityDepthFitAdjustment(
            valid: autoAdjustment.valid,
            depthZoom: baseZoom * clampedManualZoom,
            depthOffset: baseOffset + clampedManualOffset,
            pivotSceneDepth: basePivot,
            score: autoAdjustment.score,
            boneResidualMean: autoAdjustment.boneResidualMean,
            boneResidualMax: autoAdjustment.boneResidualMax,
            targetDistanceMean: autoAdjustment.targetDistanceMean,
            exactTargetCount: autoAdjustment.exactTargetCount
        )
    }

    private static func medianLegacySceneDepth(
        session: SkinnedRigSession,
        jointNames: [String]
    ) -> Float {
        var depths: [Float] = []

        for jointName in jointNames {
            guard let bone = session.bonesByCanonicalName[jointName] else {
                continue
            }

            let depth = -bone.simdWorldPosition.z

            if depth.isFinite,
               depth > 0 {
                depths.append(depth)
            }
        }

        guard !depths.isEmpty else {
            return 1
        }

        depths.sort()
        return depths[depths.count / 2]
    }

    private static func makePoseSnapshot(
        _ session: SkinnedRigSession
    ) -> DriverPoseSnapshot {
        var bones: [String: simd_float4x4] = [:]

        for jointName in session.jointOrder {
            if let bone = session.bonesByCanonicalName[jointName] {
                bones[jointName] = bone.simdTransform
            }
        }

        return DriverPoseSnapshot(
            displayRootTransform: session.displayRootNode.simdTransform,
            boneTransforms: bones
        )
    }

    private static func restorePoseSnapshot(
        _ snapshot: DriverPoseSnapshot,
        session: SkinnedRigSession
    ) {
        session.displayRootNode.simdTransform = snapshot.displayRootTransform

        for (jointName, transform) in snapshot.boneTransforms {
            session.bonesByCanonicalName[jointName]?.simdTransform = transform
        }
    }

    private static func evaluateExactDepthSolve(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment
    ) -> ExactDepthSolveEvaluation {
        var exactResiduals: [Float] = []
        var rayDistances: [Float] = []

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName] else {
                continue
            }

            let closest = closestPointOnRay(
                ray: ray,
                to: bone.simdWorldPosition
            )
            let rayDistance = simd_length(bone.simdWorldPosition - closest)

            if rayDistance.isFinite {
                rayDistances.append(rayDistance)
            }

            if let exact = exactRayDepthTarget(
                jointName: jointName,
                ray: ray,
                guidance: depthGuidance[jointName],
                remap: remap,
                adjustment: adjustment
            ) {
                let exactResidual = simd_length(bone.simdWorldPosition - exact.point)

                if exactResidual.isFinite {
                    exactResiduals.append(exactResidual)
                }
            }
        }

        let avgExact = exactResiduals.isEmpty
            ? 0
            : exactResiduals.reduce(0, +) / Float(exactResiduals.count)
        let maxExact = exactResiduals.max() ?? 0
        let avgRay = rayDistances.isEmpty
            ? 0
            : rayDistances.reduce(0, +) / Float(rayDistances.count)
        let score = avgExact + avgRay * 0.25

        return ExactDepthSolveEvaluation(
            score: score,
            avgExactResidual: avgExact,
            maxExactResidual: maxExact,
            avgRayDistance: avgRay
        )
    }

    private static func solveLegacyRayPinChain(
        _ chain: [String],
        rays: [String: JointRay],
        session: SkinnedRigSession
    ) {
        guard chain.count >= 2 else {
            return
        }

        for i in 0..<(chain.count - 1) {
            let parentName = chain[i]
            let childName = chain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let childRay = rays[childName] else {
                continue
            }

            let parentWorld = parentNode.simdWorldPosition
            let childWorld = childNode.simdWorldPosition
            let boneLength = max(
                simd_length(childWorld - parentWorld),
                0.0001
            )
            let target = legacyPointOnRayAtBoneLength(
                ray: childRay,
                parentWorld: parentWorld,
                currentChildWorld: childWorld,
                boneLength: boneLength
            )

            rotateParentToMoveChild(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: target
            )
        }
    }

    private static func solveExactDepthRayChain(
        _ chain: [String],
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment,
        session: SkinnedRigSession
    ) {
        guard chain.count >= 2 else {
            return
        }

        for childIndex in 1..<chain.count {
            let childName = chain[childIndex]

            guard let childNode = session.bonesByCanonicalName[childName],
                  let childRay = rays[childName] else {
                continue
            }

            let childTarget: SIMD3<Float>

            if let exact = exactRayDepthTarget(
                jointName: childName,
                ray: childRay,
                guidance: depthGuidance[childName],
                remap: remap,
                adjustment: adjustment
            ) {
                childTarget = exact.point
            } else {
                let parentName = chain[childIndex - 1]

                guard let parentNode = session.bonesByCanonicalName[parentName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )

                childTarget = legacyPointOnRayAtBoneLength(
                    ray: childRay,
                    parentWorld: parentWorld,
                    currentChildWorld: childWorld,
                    boneLength: boneLength
                )
            }

            for ancestorIndex in stride(
                from: childIndex - 1,
                through: 0,
                by: -1
            ) {
                let ancestorName = chain[ancestorIndex]

                guard let ancestorNode = session.bonesByCanonicalName[ancestorName] else {
                    continue
                }

                rotateAncestorToMoveDescendant(
                    ancestorNode: ancestorNode,
                    descendantNode: childNode,
                    descendantTarget: childTarget
                )
            }
        }
    }

    private static func exactRayDepthTarget(
        jointName: String,
        ray: JointRay,
        guidance: RayPinDepthGuidance?,
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment
    ) -> ExactRayDepthTarget? {
        guard let guidance,
              let point = exactRayDepthPoint(
                ray: ray,
                guidance: guidance,
                remap: remap,
                adjustment: adjustment
              ),
              let depthMeters = guidance.disparityDepthMeters,
              depthMeters > 0 else {
            return nil
        }

        return ExactRayDepthTarget(
            jointName: jointName,
            point: point,
            depthMeters: depthMeters,
            source: guidance.source,
            confidence: guidance.confidence
        )
    }

    private static func placePelvisFromExactRayDepthTargets(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment
    ) {
        let joints = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var deltas: [SIMD3<Float>] = []

        for jointName in joints {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName],
                  let exact = exactRayDepthTarget(
                    jointName: jointName,
                    ray: ray,
                    guidance: depthGuidance[jointName],
                    remap: remap,
                    adjustment: adjustment
                  ) else {
                continue
            }

            deltas.append(exact.point - bone.simdWorldPosition)
        }

        guard !deltas.isEmpty else {
            return
        }

        let average = deltas.reduce(SIMD3<Float>(0, 0, 0), +) / Float(deltas.count)
        session.displayRootNode.simdPosition += average
    }

    private static func legacyPointOnRayAtBoneLength(
        ray: JointRay,
        parentWorld: SIMD3<Float>,
        currentChildWorld: SIMD3<Float>,
        boneLength: Float
    ) -> SIMD3<Float> {
        let candidates = raySphereIntersections(
            ray: ray,
            center: parentWorld,
            radius: boneLength
        )

        if !candidates.isEmpty {
            return candidates.min {
                simd_length($0 - currentChildWorld) < simd_length($1 - currentChildWorld)
            } ?? candidates[0]
        }

        return approximatePointOnRayAtBoneLength(
            ray: ray,
            parentWorld: parentWorld,
            currentChildWorld: currentChildWorld,
            boneLength: boneLength
        )
    }

    private static func exactRayDepthPoint(
        ray: JointRay,
        guidance: RayPinDepthGuidance,
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment
    ) -> SIMD3<Float>? {
        guard guidance.accepted,
              let depthMeters = guidance.disparityDepthMeters,
              depthMeters.isFinite,
              depthMeters > 0,
              remap.valid,
              remap.scale.isFinite,
              remap.offset.isFinite,
              adjustment.valid else {
            return nil
        }

        let rawSceneDepth = remap.scale * depthMeters + remap.offset
        let adjustedSceneDepth = adjustment.pivotSceneDepth +
            adjustment.depthZoom * (rawSceneDepth - adjustment.pivotSceneDepth) +
            adjustment.depthOffset

        guard adjustedSceneDepth.isFinite,
              adjustedSceneDepth > 0 else {
            return nil
        }

        return pointOnRayAtSceneDepth(
            ray: ray,
            sceneDepth: adjustedSceneDepth
        )
    }

    private static func pointOnRayAtSceneDepth(
        ray: JointRay,
        sceneDepth: Float
    ) -> SIMD3<Float>? {
        guard sceneDepth.isFinite,
              sceneDepth > 0 else {
            return nil
        }

        let desiredZ = -sceneDepth
        let denom = ray.direction.z

        guard abs(denom) > 0.000001 else {
            return nil
        }

        let t = (desiredZ - ray.origin.z) / denom

        guard t.isFinite,
              t >= 0 else {
            return nil
        }

        return ray.point(at: t)
    }

    private static func isReasonableRemap(
        _ remap: DisparityDepthRemap
    ) -> Bool {
        guard remap.valid,
              remap.scale.isFinite,
              remap.offset.isFinite,
              remap.anchorCount >= 3 else {
            return false
        }

        guard remap.scale > 0,
              remap.scale <= 10_000,
              abs(remap.offset) <= 10_000 else {
            return false
        }

        return true
    }

    private static func raySphereIntersections(
        ray: JointRay,
        center: SIMD3<Float>,
        radius: Float
    ) -> [SIMD3<Float>] {
        let o = ray.origin
        let d = ray.direction
        let oc = o - center

        let a = simd_dot(d, d)
        let b = 2.0 * simd_dot(oc, d)
        let c = simd_dot(oc, oc) - radius * radius
        let discriminant = b * b - 4.0 * a * c

        guard discriminant >= 0 else {
            return []
        }

        let root = sqrt(discriminant)
        let t0 = (-b - root) / (2.0 * a)
        let t1 = (-b + root) / (2.0 * a)

        return [t0, t1]
            .filter { $0.isFinite && $0 >= 0 }
            .map { ray.point(at: $0) }
    }

    private static func approximatePointOnRayAtBoneLength(
        ray: JointRay,
        parentWorld: SIMD3<Float>,
        currentChildWorld: SIMD3<Float>,
        boneLength: Float
    ) -> SIMD3<Float> {
        let closest = closestPointOnRay(
            ray: ray,
            to: currentChildWorld
        )
        let direction = closest - parentWorld

        guard simd_length(direction) > 0.0001 else {
            return currentChildWorld
        }

        return parentWorld + simd_normalize(direction) * boneLength
    }

    private static func solvePinnedJointSequence(
        _ chain: [String],
        rays: [String: JointRay],
        session: SkinnedRigSession,
        passes: Int = 4
    ) {
        guard chain.count >= 2 else {
            return
        }

        for _ in 0..<passes {
            for i in 0..<(chain.count - 1) {
                let parentName = chain[i]
                let childName = chain[i + 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childRay = rays[childName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )
                let childTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    currentChild: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: childTarget
                )
            }
        }
    }

    static func logActualRigPositionError(
        session: SkinnedRigSession,
        frame: RotoRayAnimationSolveResult.Frame
    ) {
        logFitError(
            frame: frame,
            session: session,
            force: true
        )
    }

    private static func solveTorsoChain(
        rays: [String: JointRay],
        session: SkinnedRigSession
    ) {
        for i in 0..<(torsoChain.count - 1) {
            let parentName = torsoChain[i]
            let childName = torsoChain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let childRay = rays[childName] else {
                continue
            }

            let parentWorld = parentNode.simdWorldPosition
            let childWorld = childNode.simdWorldPosition
            let boneLength = max(
                simd_length(childWorld - parentWorld),
                0.0001
            )
            let target = pointOnRayAtDistanceFromParent(
                ray: childRay,
                parent: parentWorld,
                distance: boneLength,
                fallback: childWorld
            )

            rotateParentToMoveChild(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: target
            )
        }
    }

    private static func solvePinnedLimbOutsideIn(
        chain: [String],
        rays: [String: JointRay],
        session: SkinnedRigSession,
        iterations: Int = 8
    ) {
        guard chain.count >= 3 else {
            return
        }

        for _ in 0..<iterations {
            for i in stride(from: chain.count - 1, through: 1, by: -1) {
                let childName = chain[i]
                let parentName = chain[i - 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childRay = rays[childName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )

                let pinnedTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    fallback: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: pinnedTarget
                )
            }

            for i in 0..<(chain.count - 1) {
                let parentName = chain[i]
                let childName = chain[i + 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childRay = rays[childName] else {
                    continue
                }

                let parentWorld = parentNode.simdWorldPosition
                let childWorld = childNode.simdWorldPosition
                let boneLength = max(
                    simd_length(childWorld - parentWorld),
                    0.0001
                )

                let pinnedTarget = pointOnRayAtDistanceFromParent(
                    ray: childRay,
                    parent: parentWorld,
                    distance: boneLength,
                    fallback: childWorld
                )

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: pinnedTarget
                )
            }
        }
    }

    private static func solvePoleLockedLeg(
        side: String,
        rays: [String: JointRay],
        session: SkinnedRigSession,
        frameIndex: Int
    ) {
        let hipName = "\(side)UpLeg"
        let kneeName = "\(side)Leg"
        let ankleName = "\(side)Foot"
        let toeName = "\(side)ToeBase"

        guard let hip = session.bonesByCanonicalName[hipName],
              let knee = session.bonesByCanonicalName[kneeName],
              let ankle = session.bonesByCanonicalName[ankleName],
              let ankleRay = rays[ankleName] else {
            return
        }

        let hipWorld = hip.simdWorldPosition
        let kneeWorld = knee.simdWorldPosition
        let ankleWorld = ankle.simdWorldPosition

        let upperLength = max(
            simd_length(kneeWorld - hipWorld),
            0.0001
        )
        let lowerLength = max(
            simd_length(ankleWorld - kneeWorld),
            0.0001
        )
        let restPole = session.restKneePoles[side] ?? normalizeSafe(
            kneeWorld - hipWorld,
            fallback: SIMD3<Float>(0, 0, 1)
        )

        let ankleTarget = closestReachablePointOnRay(
            ray: ankleRay,
            root: hipWorld,
            minDistance: abs(upperLength - lowerLength) + 0.0001,
            maxDistance: upperLength + lowerLength - 0.0001
        )
        let solvedKnee = solveKneeWithRestPole(
            hip: hipWorld,
            ankle: ankleTarget,
            upperLength: upperLength,
            lowerLength: lowerLength,
            restPole: restPole
        )

        if frameIndex == 0 {
            print(
                """
                [CurvePinnedRotomation] \(side) knee pole solve
                  restPole: \(restPole)
                  hip: \(hipWorld)
                  ankleTarget: \(ankleTarget)
                  solvedKnee: \(solvedKnee)
                """
            )
        }

        rotateParentToMoveChild(
            parentNode: hip,
            childNode: knee,
            childTarget: solvedKnee
        )

        rotateParentToMoveChild(
            parentNode: knee,
            childNode: ankle,
            childTarget: ankleTarget
        )

        if let toe = session.bonesByCanonicalName[toeName],
           let toeRay = rays[toeName] {
            let currentFoot = ankle.simdWorldPosition
            let currentToe = toe.simdWorldPosition
            let toeLength = max(
                simd_length(currentToe - currentFoot),
                0.0001
            )
            let toeTarget = pointOnRayAtDistanceFromParent(
                ray: toeRay,
                parent: currentFoot,
                distance: toeLength,
                fallback: currentToe
            )

            rotateParentToMoveChild(
                parentNode: ankle,
                childNode: toe,
                childTarget: toeTarget
            )
        }
    }

    private static func solveKneeWithRestPole(
        hip: SIMD3<Float>,
        ankle: SIMD3<Float>,
        upperLength: Float,
        lowerLength: Float,
        restPole: SIMD3<Float>
    ) -> SIMD3<Float> {
        let hipToAnkleRaw = ankle - hip
        let distance = min(
            max(simd_length(hipToAnkleRaw), abs(upperLength - lowerLength) + 0.0001),
            upperLength + lowerLength - 0.0001
        )
        let direction = normalizeSafe(
            hipToAnkleRaw,
            fallback: SIMD3<Float>(0, -1, 0)
        )
        let x = (
            upperLength * upperLength -
            lowerLength * lowerLength +
            distance * distance
        ) / (2.0 * distance)
        let h = sqrt(max(upperLength * upperLength - x * x, 0.0))
        var pole = restPole - direction * simd_dot(restPole, direction)
        pole = normalizeSafe(
            pole,
            fallback: restPole
        )

        return hip + direction * x + pole * h
    }

    private static func closestReachablePointOnRay(
        ray: JointRay,
        root: SIMD3<Float>,
        minDistance: Float,
        maxDistance: Float
    ) -> SIMD3<Float> {
        let closest = closestPointOnRay(
            ray: ray,
            to: root
        )
        let raw = closest - root
        let distance = simd_length(raw)

        if distance > maxDistance {
            return root + normalizeSafe(
                raw,
                fallback: SIMD3<Float>(0, -1, 0)
            ) * maxDistance
        }

        if distance < minDistance {
            return root + normalizeSafe(
                raw,
                fallback: SIMD3<Float>(0, -1, 0)
            ) * minDistance
        }

        return closest
    }

    private static func rotateParentToMoveChild(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition

        let current = normalizeSafe(
            childWorld - parentWorld,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let target = normalizeSafe(
            childTarget - parentWorld,
            fallback: current
        )

        let deltaWorld = simd_quatf(
            from: current,
            to: target
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func rotateAncestorToMoveDescendant(
        ancestorNode: SCNNode,
        descendantNode: SCNNode,
        descendantTarget: SIMD3<Float>
    ) {
        let ancestorWorld = ancestorNode.simdWorldPosition
        let descendantWorld = descendantNode.simdWorldPosition
        let current = descendantWorld - ancestorWorld
        let target = descendantTarget - ancestorWorld

        guard simd_length(current) > 0.0001,
              simd_length(target) > 0.0001 else {
            return
        }

        let deltaWorld = simd_quatf(
            from: simd_normalize(current),
            to: simd_normalize(target)
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: ancestorNode
        )
    }

    private static func closestPointOnRay(
        ray: JointRay,
        to point: SIMD3<Float>
    ) -> SIMD3<Float> {
        let t = max(
            0,
            simd_dot(point - ray.origin, ray.direction)
        )

        return ray.point(at: t)
    }

    private static func pointOnRayAtDistanceFromParent(
        ray: JointRay,
        parent: SIMD3<Float>,
        distance: Float,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let direction = ray.direction
        let origin = ray.origin
        let offset = origin - parent

        let a = simd_dot(direction, direction)
        let b = 2.0 * simd_dot(offset, direction)
        let c = simd_dot(offset, offset) - distance * distance
        let discriminant = b * b - 4.0 * a * c

        if discriminant >= 0 {
            let root = sqrt(discriminant)
            let t0 = (-b - root) / (2.0 * a)
            let t1 = (-b + root) / (2.0 * a)

            let candidates = [t0, t1]
                .filter { $0.isFinite && $0 >= 0 }
                .map { ray.point(at: $0) }

            if let best = candidates.min(by: {
                simd_length_squared($0 - fallback) < simd_length_squared($1 - fallback)
            }) {
                return best
            }
        }

        let closest = closestPointOnRay(
            ray: ray,
            to: parent
        )

        let directionToRay = normalizeSafe(
            closest - parent,
            fallback: fallback - parent
        )

        return parent + directionToRay * distance
    }

    private static func pointOnRayAtDistanceFromParent(
        ray: JointRay,
        parent: SIMD3<Float>,
        distance: Float,
        currentChild: SIMD3<Float>
    ) -> SIMD3<Float> {
        let origin = ray.origin
        let direction = ray.direction
        let offset = origin - parent

        let a = simd_dot(direction, direction)
        let b = 2.0 * simd_dot(offset, direction)
        let c = simd_dot(offset, offset) - distance * distance
        let discriminant = b * b - 4.0 * a * c

        if discriminant >= 0 {
            let root = sqrt(discriminant)
            let t0 = (-b - root) / (2.0 * a)
            let t1 = (-b + root) / (2.0 * a)

            let candidates = [t0, t1]
                .filter { $0.isFinite && $0 >= 0 }
                .map { origin + direction * $0 }

            if let best = candidates.min(by: {
                simd_length_squared($0 - currentChild) < simd_length_squared($1 - currentChild)
            }) {
                return best
            }
        }

        let closest = closestPointOnRay(
            ray: ray,
            to: currentChild
        )
        let childDirection = closest - parent

        guard simd_length(childDirection) > 0.0001 else {
            return currentChild
        }

        return parent + simd_normalize(childDirection) * distance
    }

    private static func logPinnedFitError(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        frameIndex: Int
    ) {
        var worst = "none"
        var worstError: Float = 0
        var sum: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard jointName != "Hips" else {
                continue
            }

            guard let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName] else {
                continue
            }

            let point = bone.simdWorldPosition
            let closest = closestPointOnRay(
                ray: ray,
                to: point
            )
            let error = simd_length(point - closest)

            sum += error
            count += 1

            if error > worstError {
                worstError = error
                worst = jointName
            }
        }

        if frameIndex == 0 || frameIndex % 30 == 0 {
            print(
                """
                [CurvePinnedRotomation] fit error
                  frame: \(frameIndex)
                  avgRayDistance: \(String(format: "%.5f", count > 0 ? sum / count : 0))
                  worst: \(worst)
                  worstRayDistance: \(String(format: "%.5f", worstError))
                """
            )
        }
    }

    private static func makeDepthGuidedRayPinSolveStats(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        autoAdjustment: DisparityDepthFitAdjustment,
        adjustment: DisparityDepthFitAdjustment,
        frameIndex: Int,
        depthMode: SpatialRayPinDepthMode
    ) -> DepthGuidedRayPinSolveStats {
        var worst = "none"
        var worstError: Float = 0
        var sum: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard jointName != "Hips" else {
                continue
            }

            guard let bone = session.bonesByCanonicalName[jointName],
                  let ray = rays[jointName] else {
                continue
            }

            let point = bone.simdWorldPosition
            let closest = closestPointOnRay(
                ray: ray,
                to: point
            )
            let error = simd_length(point - closest)

            sum += error
            count += 1

            if error > worstError {
                worstError = error
                worst = jointName
            }
        }

        return DepthGuidedRayPinSolveStats(
            frameIndex: frameIndex,
            depthMode: depthMode,
            depthEvidenceJoints: depthGuidance.values.filter { $0.disparityDepthMeters != nil }.count,
            exactDepthTargets: depthGuidance.values.filter { $0.disparityDepthMeters != nil && $0.accepted }.count,
            depthCalibrationValid: remap.valid,
            affineScale: remap.scale,
            affineOffset: remap.offset,
            affineAnchorCount: remap.anchorCount,
            affineMedianResidual: remap.medianResidual,
            autoDepthZoom: autoAdjustment.depthZoom,
            autoDepthOffset: autoAdjustment.depthOffset,
            finalDepthZoom: adjustment.depthZoom,
            finalDepthOffset: adjustment.depthOffset,
            depthFitZoom: adjustment.depthZoom,
            depthFitOffset: adjustment.depthOffset,
            depthFitPivotSceneDepth: adjustment.pivotSceneDepth,
            depthFitScore: adjustment.score,
            depthFitBoneResidualMean: adjustment.boneResidualMean,
            depthFitBoneResidualMax: adjustment.boneResidualMax,
            depthFitTargetDistanceMean: adjustment.targetDistanceMean,
            avgRayDistance: count > 0 ? sum / count : 0,
            worstJoint: worst,
            worstRayDistance: worstError
        )
    }

    private static func logExactDepthRayPinFit(
        stats: DepthGuidedRayPinSolveStats,
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        autoAdjustment: DisparityDepthFitAdjustment,
        adjustment: DisparityDepthFitAdjustment,
        autoDepthFitEnabled: Bool,
        manualDepthZoom: Float,
        manualDepthOffset: Float,
        depthMode: SpatialRayPinDepthMode
    ) {
        guard stats.frameIndex == 0 || stats.frameIndex % 30 == 0 else {
            return
        }

        print("""
        [DepthGuidedRayPinning] active spatial solve
          frame: \(stats.frameIndex)
          mode: \(depthMode.rawValue)
          affineCalibrationValid: \(remap.valid)
          affineScale: \(remap.scale)
          affineOffset: \(remap.offset)
          affineAnchors: \(remap.anchorCount)
          affineMedianResidual: \(remap.medianResidual)
          exactDepthTargets: \(stats.exactDepthTargets)
          usesExactPointOnRayAtDisparityDepth: true
          usesClosestRaySphereCandidateForDepthJoints: false
          usesDirectStereoPoints: false
          usesConditionedStereoPointCloud: false
          usesMetersToSceneUnits: false
          avgRayDistance: \(String(format: "%.5f", stats.avgRayDistance))
          worst: \(stats.worstJoint)
          worstRayDistance: \(String(format: "%.5f", stats.worstRayDistance))
        """)

        print("""
        [DepthGuidedRayPinning] depth pan zoom controls
          frame: \(stats.frameIndex)
          autoDepthFitEnabled: \(autoDepthFitEnabled)
          manualDepthZoom: \(manualDepthZoom)
          manualDepthOffset: \(manualDepthOffset)
          autoDepthZoom: \(autoAdjustment.depthZoom)
          autoDepthOffset: \(autoAdjustment.depthOffset)
          finalDepthZoom: \(adjustment.depthZoom)
          finalDepthOffset: \(adjustment.depthOffset)
          pivotSceneDepth: \(adjustment.pivotSceneDepth)
        """)

        print("""
        [DepthGuidedRayPinning] depth fit adjustment
          frame: \(stats.frameIndex)
          autoDepthFitEnabled: \(autoDepthFitEnabled)
          depthZoom: \(adjustment.depthZoom)
          depthOffset: \(adjustment.depthOffset)
          pivotSceneDepth: \(adjustment.pivotSceneDepth)
          score: \(adjustment.score)
          boneResidualMean: \(adjustment.boneResidualMean)
          boneResidualMax: \(adjustment.boneResidualMax)
          targetDistanceMean: \(adjustment.targetDistanceMean)
          exactTargetCount: \(adjustment.exactTargetCount)
        """)

        logMajorJointExactTargets(
            session: session,
            rays: rays,
            depthGuidance: depthGuidance,
            remap: remap,
            adjustment: adjustment
        )
    }

    private static func logMajorJointExactTargets(
        session: SkinnedRigSession,
        rays: [String: JointRay],
        depthGuidance: [String: RayPinDepthGuidance],
        remap: DisparityDepthRemap,
        adjustment: DisparityDepthFitAdjustment
    ) {
        let joints = [
            "Hips",
            "Spine02",
            "Spine01",
            "Spine",
            "neck",
            "Head",
            "LeftShoulder",
            "RightShoulder",
            "LeftArm",
            "LeftForeArm",
            "LeftHand",
            "RightArm",
            "RightForeArm",
            "RightHand",
            "LeftLeg",
            "RightLeg"
        ]

        for jointName in joints {
            guard let ray = rays[jointName],
                  let guidance = depthGuidance[jointName],
                  let exact = exactRayDepthTarget(
                    jointName: jointName,
                    ray: ray,
                    guidance: guidance,
                    remap: remap,
                    adjustment: adjustment
                  ),
                  let bone = session.bonesByCanonicalName[jointName] else {
                continue
            }

            let rawSceneDepth = remap.scale * exact.depthMeters + remap.offset
            let adjustedDepth = adjustment.pivotSceneDepth +
                adjustment.depthZoom * (rawSceneDepth - adjustment.pivotSceneDepth) +
                adjustment.depthOffset
            let residual = simd_length(bone.simdWorldPosition - exact.point)
            let zResidual = abs(bone.simdWorldPosition.z - exact.point.z)

            print("""
            [DepthGuidedRayPinning] exact disparity target
              joint: \(jointName)
              source: \(exact.source)
              depthMeters: \(exact.depthMeters)
              rawSceneDepth: \(rawSceneDepth)
              adjustedDepth: \(adjustedDepth)
              exactTarget: \(exact.point)
              finalBone: \(bone.simdWorldPosition)
              residual: \(residual)
              zResidual: \(zResidual)
              confidence: \(exact.confidence)
            """)
        }
    }

    private static func lockBase(
        session: SkinnedRigSession,
        targets: [String: SIMD3<Float>]
    ) {
        guard let hips = session.bonesByCanonicalName["Hips"],
              let spine = session.bonesByCanonicalName["Spine"],
              let hipsTarget = targets["Hips"],
              let spineTarget = targets["Spine"] else {
            return
        }

        let current = normalizeSafe(
            spine.simdWorldPosition - hips.simdWorldPosition,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let target = normalizeSafe(
            spineTarget - hipsTarget,
            fallback: current
        )

        let deltaWorld = simd_quatf(
            from: current,
            to: target
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: hips
        )
    }

    private static func solveChainToPositions(
        _ chain: [String],
        targets: [String: SIMD3<Float>],
        session: SkinnedRigSession,
        cameraOrigin: SIMD3<Float>
    ) {
        guard chain.count >= 2 else {
            return
        }

        for i in 0..<(chain.count - 1) {
            let parentName = chain[i]
            let childName = chain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let childTarget = targets[childName] else {
                continue
            }

            rotateParentTowardChildTarget(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: childTarget,
                cameraOrigin: cameraOrigin
            )
        }
    }

    private static func rotateParentTowardChildTarget(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition
        let boneLength = max(
            simd_length(childWorld - parentWorld),
            0.0001
        )

        let adjustedTarget = bestTargetNearRay(
            originalTarget: childTarget,
            cameraOrigin: cameraOrigin,
            maxZOffset: 2.0,
            samples: 17,
            score: { candidate in
                abs(simd_length(candidate - parentWorld) - boneLength)
            }
        )

        let currentVector = normalizeSafe(
            childWorld - parentWorld,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let targetVector = normalizeSafe(
            adjustedTarget - parentWorld,
            fallback: currentVector
        )

        let deltaWorld = simd_quatf(
            from: currentVector,
            to: targetVector
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func bestTargetNearRay(
        originalTarget: SIMD3<Float>,
        cameraOrigin: SIMD3<Float>,
        maxZOffset: Float = 2.0,
        samples: Int = 17,
        score: (SIMD3<Float>) -> Float
    ) -> SIMD3<Float> {
        let rayDir = normalizeSafe(
            originalTarget - cameraOrigin,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        var best = originalTarget
        var bestScore = score(originalTarget)

        for i in 0..<samples {
            let t = Float(i) / Float(max(samples - 1, 1))
            let offset = -maxZOffset + 2.0 * maxZOffset * t
            let candidate = originalTarget + rayDir * offset
            let candidateScore = score(candidate)

            if candidateScore < bestScore {
                bestScore = candidateScore
                best = candidate
            }
        }

        return best
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorldRotation = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorldRotation) * deltaWorld * parentWorldRotation

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func logFitError(
        frame: RotoRayAnimationSolveResult.Frame,
        session: SkinnedRigSession,
        force: Bool = false
    ) {
        var worstJoint = "none"
        var worstError: Float = 0
        var averageError: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = frame.jointPositions[jointName] else {
                continue
            }

            let error = simd_length(bone.simdWorldPosition - target)
            averageError += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        let avgError = count > 0 ? averageError / count : 0

        if force || frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
            print(
                """
                [SkinnedRigRotomationDriver] position fit error
                  frame: \(frame.frameIndex)
                  avgError: \(String(format: "%.5f", avgError))
                  worstJoint: \(worstJoint)
                  worstError: \(String(format: "%.5f", worstError))
                """
            )
        }
    }

    private static func normalizeSafe(
        _ v: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.000001 else {
            return fallback
        }

        return v / len
    }
}

enum StereoTargetRigRotomationDriver {
    static func rotomateFrameWithStereoTargets(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        metersToSceneUnits: Float,
        iterations: Int = 6
    ) {
        let targetScale = max(metersToSceneUnits, 0.0001)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)
        placeRootFromStereoHipsOrUpperLegs(
            frame,
            session: session,
            targetScale: targetScale
        )

        solveChain(
            ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["Hips", "Spine", "neck", "Head", "headfront"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )
        solveChain(
            ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
            frame,
            session: session,
            targetScale: targetScale,
            passes: iterations
        )

        SCNTransaction.commit()
        logFitError(
            frame,
            session: session,
            targetScale: targetScale
        )
    }

    private static func resetBonesToRestOnly(
        session: SkinnedRigSession
    ) {
        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName] else {
                continue
            }

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation
            bone.simdScale = restScale
        }
    }

    private static func placeRootFromStereoHipsOrUpperLegs(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float
    ) {
        let targetNames = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var deltas: [SIMD3<Float>] = []

        for name in targetNames {
            guard let bone = session.bonesByCanonicalName[name],
                  let target = stereoPosition(
                    name,
                    in: frame,
                    targetScale: targetScale
                  ) else {
                continue
            }

            deltas.append(target - bone.simdWorldPosition)
        }

        guard !deltas.isEmpty else {
            return
        }

        let average = deltas.reduce(
            SIMD3<Float>(0, 0, 0),
            +
        ) / Float(deltas.count)

        session.displayRootNode.simdPosition += average
    }

    private static func solveChain(
        _ chain: [String],
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float,
        passes: Int = 4
    ) {
        guard chain.count >= 2 else {
            return
        }

        for _ in 0..<passes {
            for i in 0..<(chain.count - 1) {
                let parentName = chain[i]
                let childName = chain[i + 1]

                guard let parentNode = session.bonesByCanonicalName[parentName],
                      let childNode = session.bonesByCanonicalName[childName],
                      let childTarget = stereoPosition(
                        childName,
                        in: frame,
                        targetScale: targetScale
                      ) else {
                    continue
                }

                rotateParentToMoveChild(
                    parentNode: parentNode,
                    childNode: childNode,
                    childTarget: childTarget
                )
            }
        }
    }

    private static func stereoPosition(
        _ joint: String,
        in frame: StereoMeshyJointCapture.Frame,
        targetScale: Float
    ) -> SIMD3<Float>? {
        guard let target = frame.joints[joint],
              target.validStereo,
              target.positionCameraXYZ.count == 3 else {
            return nil
        }

        return SIMD3<Float>(
            Float(target.positionCameraXYZ[0]),
            Float(target.positionCameraXYZ[1]),
            Float(target.positionCameraXYZ[2])
        ) * targetScale
    }

    private static func rotateParentToMoveChild(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition
        let current = normalizeSafe(
            childWorld - parentWorld,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let target = normalizeSafe(
            childTarget - parentWorld,
            fallback: current
        )
        let deltaWorld = simd_quatf(
            from: current,
            to: target
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorldRotation = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorldRotation) * deltaWorld * parentWorldRotation

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000001 else {
            return fallback
        }

        return value / length
    }

    private static func logFitError(
        _ frame: StereoMeshyJointCapture.Frame,
        session: SkinnedRigSession,
        targetScale: Float
    ) {
        var worstJoint = "none"
        var worstError: Float = 0
        var averageError: Float = 0
        var count: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = stereoPosition(
                    jointName,
                    in: frame,
                    targetScale: targetScale
                  ) else {
                continue
            }

            let error = simd_length(
                bone.simdWorldPosition - target
            )
            averageError += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        guard count > 0,
              frame.frameIndex == 0 || frame.frameIndex % 30 == 0 else {
            return
        }

        averageError /= count

        print("""
        [StereoTargetRigRotomation] fit error
          frame: \(frame.frameIndex)
          avgPositionError: \(averageError)
          worstJoint: \(worstJoint)
          worstError: \(worstError)
          metersToSceneUnits: \(targetScale)
        """)
    }
}

enum ConditionedStereoTargetRigRotomationDriver {
    static func rotomateFrame(
        _ frame: ConditionedStereoJointCapture.Frame,
        session: SkinnedRigSession,
        stereoToRigAlignment: StereoToRigAlignment,
        iterations: Int = 6
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)
        placeRootFromConditionedPelvis(
            frame,
            session: session,
            alignment: stereoToRigAlignment
        )

        for _ in 0..<iterations {
            solveChain(
                ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["Hips", "Spine", "neck", "Head", "headfront"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
        }

        SCNTransaction.commit()
        logFitError(
            frame,
            session: session,
            alignment: stereoToRigAlignment
        )
    }

    private static func resetBonesToRestOnly(
        session: SkinnedRigSession
    ) {
        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName] else {
                continue
            }

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation
            bone.simdScale = restScale
        }
    }

    private static func conditionedPosition(
        _ joint: String,
        in frame: ConditionedStereoJointCapture.Frame,
        alignment: StereoToRigAlignment
    ) -> SIMD3<Float>? {
        guard let target = frame.joints[joint],
              target.positionCameraXYZ.count == 3 else {
            return nil
        }

        let stereoMeters = SIMD3<Float>(
            Float(target.positionCameraXYZ[0]),
            Float(target.positionCameraXYZ[1]),
            Float(target.positionCameraXYZ[2])
        )

        return StereoToRigAlignmentSolver.transform(
            stereoMeters,
            alignment: alignment
        )
    }

    private static func placeRootFromConditionedPelvis(
        _ frame: ConditionedStereoJointCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        let targetNames = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var deltas: [SIMD3<Float>] = []

        for name in targetNames {
            guard let bone = session.bonesByCanonicalName[name],
                  let target = conditionedPosition(
                    name,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            deltas.append(target - bone.simdWorldPosition)
        }

        guard !deltas.isEmpty else {
            return
        }

        let averageDelta = deltas.reduce(
            SIMD3<Float>(0, 0, 0),
            +
        ) / Float(deltas.count)

        session.displayRootNode.simdPosition += averageDelta
    }

    private static func solveChain(
        _ chain: [String],
        _ frame: ConditionedStereoJointCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        guard chain.count >= 2 else {
            return
        }

        for i in 0..<(chain.count - 1) {
            let parentName = chain[i]
            let childName = chain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let childTarget = conditionedPosition(
                    childName,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            rotateParentToMoveChild(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: childTarget
            )
        }
    }

    private static func rotateParentToMoveChild(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition
        let current = childWorld - parentWorld
        let target = childTarget - parentWorld

        guard simd_length(current) > 0.0001,
              simd_length(target) > 0.0001 else {
            return
        }

        let deltaWorld = simd_quatf(
            from: simd_normalize(current),
            to: simd_normalize(target)
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorld = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorld) * deltaWorld * parentWorld

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func logFitError(
        _ frame: ConditionedStereoJointCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        var total: Float = 0
        var count: Float = 0
        var worstJoint = "none"
        var worstError: Float = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = conditionedPosition(
                    jointName,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            let error = simd_length(bone.simdWorldPosition - target)
            total += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        guard frame.frameIndex == 0 || frame.frameIndex % 30 == 0 else {
            return
        }

        print("""
        [ConditionedStereoTargetRigRotomation] fit error
          frame: \(frame.frameIndex)
          avg: \(count > 0 ? total / count : 0)
          worstJoint: \(worstJoint)
          worstError: \(worstError)
          alignmentValid: \(alignment.isValid)
          alignmentScale: \(alignment.scale)
          alignmentTranslation: \(alignment.translation.simdFloat)
        """)
    }
}

enum FusedStereoTargetRigRotomationDriver {
    static func rotomateFrame(
        _ frame: FusedStereoJointTargetCapture.Frame,
        session: SkinnedRigSession,
        stereoToRigAlignment: StereoToRigAlignment,
        iterations: Int = 6
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        resetBonesToRestOnly(session: session)
        placeRootFromFusedPelvis(
            frame,
            session: session,
            alignment: stereoToRigAlignment
        )

        for _ in 0..<iterations {
            solveChain(
                ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["Hips", "Spine", "neck", "Head", "headfront"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
            solveChain(
                ["RightShoulder", "RightArm", "RightForeArm", "RightHand"],
                frame,
                session: session,
                alignment: stereoToRigAlignment
            )
        }

        SCNTransaction.commit()
        logFitError(
            frame,
            session: session,
            alignment: stereoToRigAlignment
        )
    }

    private static func resetBonesToRestOnly(
        session: SkinnedRigSession
    ) {
        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName] else {
                continue
            }

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation
            bone.simdScale = restScale
        }
    }

    private static func fusedPosition(
        _ joint: String,
        in frame: FusedStereoJointTargetCapture.Frame,
        alignment: StereoToRigAlignment
    ) -> SIMD3<Float>? {
        guard let target = frame.joints[joint],
              !target.rejected,
              let values = target.positionCameraXYZ,
              values.count == 3 else {
            return nil
        }

        let stereoMeters = SIMD3<Float>(
            Float(values[0]),
            Float(values[1]),
            Float(values[2])
        )

        return StereoToRigAlignmentSolver.transform(
            stereoMeters,
            alignment: alignment
        )
    }

    private static func fusedWeight(
        _ joint: String,
        in frame: FusedStereoJointTargetCapture.Frame
    ) -> Float {
        guard let target = frame.joints[joint],
              !target.rejected else {
            return 0
        }

        let base = Float(max(0.05, min(target.confidence, 1.0)))

        if target.status.contains("held") {
            return max(0.05, base * 0.5)
        }

        return base
    }

    private static func placeRootFromFusedPelvis(
        _ frame: FusedStereoJointTargetCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        let targetNames = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg"
        ]
        var weightedDelta = SIMD3<Float>(0, 0, 0)
        var totalWeight: Float = 0

        for name in targetNames {
            guard let bone = session.bonesByCanonicalName[name],
                  let target = fusedPosition(
                    name,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            let weight = fusedWeight(name, in: frame)
            weightedDelta += (target - bone.simdWorldPosition) * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else {
            return
        }

        session.displayRootNode.simdPosition += weightedDelta / totalWeight
    }

    private static func solveChain(
        _ chain: [String],
        _ frame: FusedStereoJointTargetCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        guard chain.count >= 2 else {
            return
        }

        for i in 0..<(chain.count - 1) {
            let parentName = chain[i]
            let childName = chain[i + 1]

            guard let parentNode = session.bonesByCanonicalName[parentName],
                  let childNode = session.bonesByCanonicalName[childName],
                  let target = fusedPosition(
                    childName,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            let weight = fusedWeight(childName, in: frame)
            let childWorld = childNode.simdWorldPosition
            let weightedTarget = childWorld + (target - childWorld) * weight

            rotateParentToMoveChild(
                parentNode: parentNode,
                childNode: childNode,
                childTarget: weightedTarget
            )
        }
    }

    private static func rotateParentToMoveChild(
        parentNode: SCNNode,
        childNode: SCNNode,
        childTarget: SIMD3<Float>
    ) {
        let parentWorld = parentNode.simdWorldPosition
        let childWorld = childNode.simdWorldPosition
        let current = childWorld - parentWorld
        let target = childTarget - parentWorld

        guard simd_length(current) > 0.0001,
              simd_length(target) > 0.0001 else {
            return
        }

        let deltaWorld = simd_quatf(
            from: simd_normalize(current),
            to: simd_normalize(target)
        )

        applyWorldRotationDelta(
            deltaWorld,
            to: parentNode
        )
    }

    private static func applyWorldRotationDelta(
        _ deltaWorld: simd_quatf,
        to node: SCNNode
    ) {
        guard let parent = node.parent else {
            node.simdOrientation = deltaWorld * node.simdOrientation
            return
        }

        let parentWorld = parent.simdWorldOrientation
        let localDelta = simd_inverse(parentWorld) * deltaWorld * parentWorld

        node.simdOrientation = localDelta * node.simdOrientation
    }

    private static func logFitError(
        _ frame: FusedStereoJointTargetCapture.Frame,
        session: SkinnedRigSession,
        alignment: StereoToRigAlignment
    ) {
        var total: Float = 0
        var count: Float = 0
        var worstJoint = "none"
        var worstError: Float = 0
        var rejected = 0

        for jointName in session.jointOrder {
            if frame.joints[jointName]?.rejected == true {
                rejected += 1
            }

            guard let bone = session.bonesByCanonicalName[jointName],
                  let target = fusedPosition(
                    jointName,
                    in: frame,
                    alignment: alignment
                  ) else {
                continue
            }

            let error = simd_length(bone.simdWorldPosition - target)
            total += error
            count += 1

            if error > worstError {
                worstError = error
                worstJoint = jointName
            }
        }

        guard frame.frameIndex == 0 || frame.frameIndex % 30 == 0 else {
            return
        }

        print("""
        [FusedStereoTargetRigRotomation] fit error
          frame: \(frame.frameIndex)
          avg: \(count > 0 ? total / count : 0)
          worstJoint: \(worstJoint)
          worstError: \(worstError)
          rejected: \(rejected)
          alignmentValid: \(alignment.isValid)
          alignmentScale: \(alignment.scale)
          alignmentTranslation: \(alignment.translation.simdFloat)
        """)
    }
}
