import Foundation
import SceneKit
import simd

enum StereoToRigAlignmentSolver {
    static func solveInitialAlignment(
        stereoFrame: ConditionedStereoJointCapture.Frame,
        session: SkinnedRigSession
    ) -> StereoToRigAlignment? {
        let targetJointNames = [
            "Hips",
            "LeftUpLeg",
            "RightUpLeg",
            "Spine",
            "LeftShoulder",
            "RightShoulder"
        ]

        var stereoPoints: [SIMD3<Float>] = []
        var rigPoints: [SIMD3<Float>] = []

        for jointName in targetJointNames {
            guard let stereo = stereoFrame.joints[jointName],
                  stereo.positionCameraXYZ.count == 3,
                  let bone = session.bonesByCanonicalName[jointName] else {
                continue
            }

            stereoPoints.append(
                SIMD3<Float>(
                    Float(stereo.positionCameraXYZ[0]),
                    Float(stereo.positionCameraXYZ[1]),
                    Float(stereo.positionCameraXYZ[2])
                )
            )
            rigPoints.append(bone.simdWorldPosition)
        }

        guard stereoPoints.count >= 2 else {
            return nil
        }

        let stereoCenter = average(stereoPoints)
        let rigCenter = average(rigPoints)

        var stereoRadius: Float = 0
        var rigRadius: Float = 0

        for index in stereoPoints.indices {
            stereoRadius += simd_length(stereoPoints[index] - stereoCenter)
            rigRadius += simd_length(rigPoints[index] - rigCenter)
        }

        stereoRadius /= Float(stereoPoints.count)
        rigRadius /= Float(rigPoints.count)

        guard stereoRadius > 0.0001 else {
            return nil
        }

        let scale = rigRadius / stereoRadius
        let translation = rigCenter - stereoCenter * scale

        return StereoToRigAlignment(
            isValid: true,
            scale: scale,
            translation: SIMD3Codable(translation),
            rotationYRadians: 0
        )
    }

    static func transform(
        _ p: SIMD3<Float>,
        alignment: StereoToRigAlignment
    ) -> SIMD3<Float> {
        let scaled = p * alignment.scale
        let yaw = alignment.rotationYRadians
        let c = cos(yaw)
        let s = sin(yaw)
        let rotated = SIMD3<Float>(
            scaled.x * c + scaled.z * s,
            scaled.y,
            -scaled.x * s + scaled.z * c
        )

        return rotated + alignment.translation.simdFloat
    }

    private static func average(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else {
            return SIMD3<Float>(0, 0, 0)
        }

        return points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)
    }
}
