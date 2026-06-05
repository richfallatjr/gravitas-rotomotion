import CoreGraphics
import Foundation
import simd

enum RotoRayAnimationSolver {
    static func solveAnimation(
        normalized: NormalizedMeshyPoseCapture,
        videoPlaneSize: CGSize,
        mode: RotoRayConstrainedIKSolver.Mode,
        targetHeightMeters: Double = 1.74,
        sceneUnitsPerMeter: Double = 5.0,
        referenceArmature: RotoReferenceArmature? = nil,
        rootDepthZ: Float? = nil,
        cameraOrigin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        videoPlaneZ: Float = -2000,
        settings: RotoRayConstrainedIKSolver.Settings = .default
    ) -> RotoRayAnimationSolveResult {
        var results: [RotoRayAnimationSolveResult.Frame] = []
        var previousPositions: [String: SIMD3<Float>]?
        var previousBodyBasis: RotoBodyBasis?
        var previousLocalRotations: [String: SIMD4<Float>]?
        let calibration = scaledArmature(
            targetHeightMeters: targetHeightMeters,
            sceneUnitsPerMeter: sceneUnitsPerMeter,
            referenceArmature: referenceArmature
        )

        for frame in normalized.frames {
            let solved = RotoRayConstrainedIKSolver.solve(
                frame: frame,
                armature: calibration.armature,
                cameraOrigin: cameraOrigin,
                videoPlaneSize: videoPlaneSize,
                videoPlaneZ: videoPlaneZ,
                mode: mode,
                previousFramePositions: previousPositions,
                previousBodyBasis: previousBodyBasis,
                rootDepthZ: rootDepthZ,
                settings: settings
            )

            let stableLocalRotations = RotoLocalRotationContinuityFilter.stabilize(
                solved.localRotationsWXYZ,
                previous: previousLocalRotations
            )

            previousPositions = solved.jointPositions
            previousBodyBasis = solved.bodyBasis
            previousLocalRotations = stableLocalRotations

            results.append(
                RotoRayAnimationSolveResult.Frame(
                    frameIndex: solved.frameIndex,
                    timeSeconds: solved.timeSeconds,
                    jointPositions: solved.jointPositions,
                    localRotationsWXYZ: stableLocalRotations,
                    projectionErrors: solved.projectionErrors,
                    solvedJoints: solved.solvedJoints,
                    missingJoints: solved.missingJoints,
                    bodyBasis: solved.bodyBasis
                )
            )
        }

        return RotoRayAnimationSolveResult(
            schema: "com.gravitas.rotomotion.ray_constrained_ik_animation.v0",
            rigID: CanonicalRig.rigID,
            rigVersion: CanonicalRig.rigVersion,
            sourceKind: "normalized_meshy24_camera_ray_ik",
            targetHeightMeters: targetHeightMeters,
            sceneUnitsPerMeter: sceneUnitsPerMeter,
            armatureSceneScale: calibration.armatureSceneScale,
            frameCount: results.count,
            frames: results
        )
    }

    private static func scaledArmature(
        targetHeightMeters: Double,
        sceneUnitsPerMeter: Double,
        referenceArmature: RotoReferenceArmature?
    ) -> (
        armature: RotoReferenceArmature,
        armatureSceneScale: Double
    ) {
        let base = RotoReferenceArmature.meshy24Default

        if let referenceArmature {
            return (
                armature: referenceArmature,
                armatureSceneScale: referenceArmature.restHeight / base.restHeight
            )
        }

        let targetMeters = max(targetHeightMeters, 0.0001)
        let meterScale = max(sceneUnitsPerMeter, 0.0001)
        let armatureSceneHeight = targetMeters * meterScale
        let armatureSceneScale = armatureSceneHeight / base.restHeight

        return (
            armature: base.scaled(by: armatureSceneScale),
            armatureSceneScale: armatureSceneScale
        )
    }
}
