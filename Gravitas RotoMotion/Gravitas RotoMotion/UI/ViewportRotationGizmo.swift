import AppKit
import SceneKit
import simd

final class ViewportJointRotationGizmo {
    enum Axis: String {
        case x
        case y
        case z
    }

    let root = SCNNode()

    private let xRing = SCNNode()
    private let yRing = SCNNode()
    private let zRing = SCNNode()

    private let xAxisLine = SCNNode()
    private let yAxisLine = SCNNode()
    private let zAxisLine = SCNNode()

    private let axisLineLength: CGFloat = 0.55
    private let ringRadius: CGFloat = 0.42
    private let ringPipeRadius: CGFloat = 0.008

    init() {
        root.name = "ViewportJointRotationGizmoRoot"
        root.renderingOrder = 2000
        root.isHidden = true

        xRing.name = "JointRotationGizmo_X"
        yRing.name = "JointRotationGizmo_Y"
        zRing.name = "JointRotationGizmo_Z"

        xRing.geometry = makeRing(color: .systemRed)
        yRing.geometry = makeRing(color: .systemGreen)
        zRing.geometry = makeRing(color: .systemBlue)

        // SCNTorus lies in local XY plane, normal along local Z.
        xRing.simdEulerAngles = SIMD3<Float>(0, .pi / 2.0, 0)
        yRing.simdEulerAngles = SIMD3<Float>(.pi / 2.0, 0, 0)
        zRing.simdEulerAngles = SIMD3<Float>(0, 0, 0)

        xAxisLine.name = "JointRotationGizmo_XAxisLine"
        yAxisLine.name = "JointRotationGizmo_YAxisLine"
        zAxisLine.name = "JointRotationGizmo_ZAxisLine"

        xAxisLine.geometry = makeAxisLine(color: .systemRed)
        yAxisLine.geometry = makeAxisLine(color: .systemGreen)
        zAxisLine.geometry = makeAxisLine(color: .systemBlue)

        xAxisLine.simdEulerAngles = SIMD3<Float>(0, 0, .pi / 2.0)
        zAxisLine.simdEulerAngles = SIMD3<Float>(.pi / 2.0, 0, 0)

        for node in [xRing, yRing, zRing, xAxisLine, yAxisLine, zAxisLine] {
            node.renderingOrder = 2000
            root.addChildNode(node)
        }
    }

    func setVisible(_ visible: Bool) {
        root.isHidden = !visible
    }

    func update(
        selectedBone: SCNNode?,
        cameraNode: SCNNode,
        view: SCNView,
        space: RotationGizmoSpace,
        visible: Bool
    ) {
        guard visible, let selectedBone else {
            root.isHidden = true
            return
        }

        root.isHidden = false
        root.simdPosition = selectedBone.simdWorldPosition

        switch space {
        case .local:
            root.simdOrientation = selectedBone.simdWorldOrientation
        case .world:
            root.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }

        applyConstantScreenSize(cameraNode: cameraNode, view: view)
    }

    func worldAxis(for axis: Axis) -> SIMD3<Float> {
        switch axis {
        case .x:
            return normalizeSafe(
                root.simdWorldTransform.columns.0.xyz,
                fallback: SIMD3<Float>(1, 0, 0)
            )
        case .y:
            return normalizeSafe(
                root.simdWorldTransform.columns.1.xyz,
                fallback: SIMD3<Float>(0, 1, 0)
            )
        case .z:
            return normalizeSafe(
                root.simdWorldTransform.columns.2.xyz,
                fallback: SIMD3<Float>(0, 0, 1)
            )
        }
    }

    func axisFromHitNode(_ node: SCNNode?) -> Axis? {
        var current = node

        while let n = current {
            switch n.name {
            case xRing.name:
                return .x
            case yRing.name:
                return .y
            case zRing.name:
                return .z
            default:
                current = n.parent
            }
        }

        return nil
    }

    private func applyConstantScreenSize(
        cameraNode: SCNNode,
        view: SCNView
    ) {
        let cameraPosition = cameraNode.simdWorldPosition
        let distance = max(simd_length(root.simdPosition - cameraPosition), 0.001)

        let worldHeight: Float
        if let camera = cameraNode.camera,
           camera.usesOrthographicProjection {
            worldHeight = Float(camera.orthographicScale)
        } else {
            let fov = Float(cameraNode.camera?.fieldOfView ?? 69.4) * .pi / 180.0
            worldHeight = 2.0 * distance * tan(fov * 0.5)
        }

        let desiredDiameterPixels: Float = 150.0
        let pixelHeight = max(Float(view.bounds.height), 1.0)
        let worldDiameter = worldHeight * desiredDiameterPixels / pixelHeight
        let worldRadius = worldDiameter * 0.5

        root.simdScale = SIMD3<Float>(
            repeating: worldRadius / Float(ringRadius)
        )
    }

    private func makeRing(color: NSColor) -> SCNGeometry {
        let torus = SCNTorus(
            ringRadius: ringRadius,
            pipeRadius: ringPipeRadius
        )

        let material = makeMaterial(color: color)
        torus.materials = [material]
        return torus
    }

    private func makeAxisLine(color: NSColor) -> SCNGeometry {
        let cylinder = SCNCylinder(
            radius: 0.006,
            height: axisLineLength
        )

        cylinder.materials = [makeMaterial(color: color)]
        return cylinder
    }

    private func makeMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    private func normalizeSafe(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000001 else {
            return fallback
        }

        return value / length
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}
