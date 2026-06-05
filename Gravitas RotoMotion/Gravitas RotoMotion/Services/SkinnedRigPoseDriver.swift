import Foundation
import SceneKit
import simd

enum RigRotationApplyMode: String {
    case restThenDelta
    case deltaThenRest
    case deltaOnly
}

enum CanonicalMirrorMap {
    static let solvedSourceForTargetBone: [String: String] = [
        "LeftUpLeg": "RightUpLeg",
        "LeftLeg": "RightLeg",
        "LeftFoot": "RightFoot",
        "LeftToeBase": "RightToeBase",

        "RightUpLeg": "LeftUpLeg",
        "RightLeg": "LeftLeg",
        "RightFoot": "LeftFoot",
        "RightToeBase": "LeftToeBase",

        "LeftShoulder": "RightShoulder",
        "LeftArm": "RightArm",
        "LeftForeArm": "RightForeArm",
        "LeftHand": "RightHand",

        "RightShoulder": "LeftShoulder",
        "RightArm": "LeftArm",
        "RightForeArm": "LeftForeArm",
        "RightHand": "LeftHand",

        "Hips": "Hips",
        "Spine02": "Spine02",
        "Spine01": "Spine01",
        "Spine": "Spine",
        "neck": "neck",
        "Head": "Head",
        "head_end": "head_end",
        "headfront": "headfront"
    ]

    static func sourceJoint(forTargetBone target: String) -> String {
        solvedSourceForTargetBone[target] ?? target
    }
}

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
        to session: SkinnedRigSession,
        mode: RigRotationApplyMode = .restThenDelta
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        var applied = 0
        var missing = 0

        resetToRestWithoutTransaction(session: session)

        for targetBoneName in session.jointOrder {
            let sourceSolvedJointName = CanonicalMirrorMap.sourceJoint(
                forTargetBone: targetBoneName
            )

            guard let bone = session.bonesByCanonicalName[targetBoneName],
                  let restPosition = session.restLocalPositions[targetBoneName],
                  let restOrientation = session.restLocalOrientations[targetBoneName],
                  let restScale = session.restLocalScales[targetBoneName],
                  let eulerXYZ = frame.localRotationsEulerXYZ[sourceSolvedJointName] else {
                missing += 1
                continue
            }

            let delta = quaternionFromEulerXYZ(eulerXYZ)

            bone.simdPosition = restPosition

            switch mode {
            case .restThenDelta:
                bone.simdOrientation = restOrientation * delta
            case .deltaThenRest:
                bone.simdOrientation = delta * restOrientation
            case .deltaOnly:
                bone.simdOrientation = delta
            }

            bone.simdScale = restScale

            applied += 1
        }

        SCNTransaction.commit()

        if frame.frameIndex == 0 || frame.frameIndex % 30 == 0 {
            print(
                """
                [SkinnedRigPoseDriver] apply frame
                  frame: \(frame.frameIndex)
                  mode: \(mode.rawValue)
                  jointOrder: \(session.jointOrder.count)
                """
            )

            print(
                """
                [SkinnedRigPoseDriver] Applied mirrored camera-facing solved frame
                  frame: \(frame.frameIndex)
                  rotationApplyMode: \(mode.rawValue)
                  applied: \(applied)
                  missing: \(missing)
                  sideMap: left<->right enabled
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

    private static func quaternionFromEulerXYZ(_ values: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(
            angle: values.x,
            axis: SIMD3<Float>(1, 0, 0)
        )
        let qy = simd_quatf(
            angle: values.y,
            axis: SIMD3<Float>(0, 1, 0)
        )
        let qz = simd_quatf(
            angle: values.z,
            axis: SIMD3<Float>(0, 0, 1)
        )

        return qz * qy * qx
    }
}
