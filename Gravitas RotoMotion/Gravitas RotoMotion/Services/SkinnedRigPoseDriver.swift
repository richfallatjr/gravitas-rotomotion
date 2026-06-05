import Foundation
import SceneKit
import simd

enum SkinnedRigPoseDriver {
    static func resetToRest(
        session: SkinnedRigSession
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

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

        SCNTransaction.commit()
    }

    static func applySolvedFrame(
        _ frame: RotoRayAnimationSolveResult.Frame,
        to session: SkinnedRigSession
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        var applied = 0
        var missing = 0

        resetToRestWithoutTransaction(session: session)

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName],
                  let qWXYZ = frame.localRotationsWXYZ[jointName] else {
                missing += 1
                continue
            }

            let delta = simd_quatf(
                vector: SIMD4<Float>(
                    qWXYZ.y,
                    qWXYZ.z,
                    qWXYZ.w,
                    qWXYZ.x
                )
            )

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation * delta
            bone.simdScale = restScale

            applied += 1
        }

        SCNTransaction.commit()

        if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
            print(
                """
                [SkinnedRigPoseDriver] Applied solved frame
                  frame: \(frame.frameIndex)
                  applied: \(applied)
                  missing: \(missing)
                """
            )
        }
    }

    private static func resetToRestWithoutTransaction(
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
}
