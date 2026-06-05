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
                  let rest = session.restLocalTransforms[jointName] else {
                continue
            }

            bone.simdTransform = rest
        }

        SCNTransaction.commit()
    }

    static func applySolvedFrame(
        _ frame: RotoRayAnimationSolveResult.Frame,
        to session: SkinnedRigSession
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let rest = session.restLocalTransforms[jointName] else {
                continue
            }

            bone.simdTransform = rest
        }

        for jointName in session.jointOrder {
            guard let bone = session.bonesByCanonicalName[jointName],
                  let restPosition = session.restLocalPositions[jointName],
                  let restOrientation = session.restLocalOrientations[jointName],
                  let restScale = session.restLocalScales[jointName],
                  let localRotation = frame.localRotationsWXYZ[jointName] else {
                continue
            }

            let delta = simd_quatf(
                ix: localRotation.y,
                iy: localRotation.z,
                iz: localRotation.w,
                r: localRotation.x
            )

            bone.simdPosition = restPosition
            bone.simdOrientation = restOrientation * delta
            bone.simdScale = restScale
        }

        SCNTransaction.commit()
    }
}
