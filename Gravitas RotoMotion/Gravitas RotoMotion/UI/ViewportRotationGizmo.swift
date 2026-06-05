import AppKit
import SceneKit
import simd

final class ViewportRotationGizmo {
    enum Axis: String {
        case x
        case y
        case z
        case screen
    }

    let root = SCNNode()
    private let xRing = SCNNode()
    private let yRing = SCNNode()
    private let zRing = SCNNode()
    private let screenRing = SCNNode()

    var radius: CGFloat = 0.35

    init() {
        root.name = "ViewportRotationGizmoRoot"
        root.renderingOrder = 1000

        xRing.name = "RotationGizmoAxis_X"
        yRing.name = "RotationGizmoAxis_Y"
        zRing.name = "RotationGizmoAxis_Z"
        screenRing.name = "RotationGizmoAxis_SCREEN"

        xRing.geometry = makeRingGeometry(color: .systemRed)
        yRing.geometry = makeRingGeometry(color: .systemGreen)
        zRing.geometry = makeRingGeometry(color: .systemBlue)
        screenRing.geometry = makeRingGeometry(color: .systemYellow)

        xRing.eulerAngles = SCNVector3(0, Float.pi / 2.0, 0)
        yRing.eulerAngles = SCNVector3(Float.pi / 2.0, 0, 0)
        zRing.eulerAngles = SCNVector3(0, 0, 0)

        for ring in [xRing, yRing, zRing, screenRing] {
            ring.renderingOrder = 1000
            root.addChildNode(ring)
        }

        root.isHidden = true
    }

    func setVisible(_ visible: Bool) {
        root.isHidden = !visible
    }

    func update(
        selectedJointWorldPosition: SIMD3<Float>?,
        cameraNode: SCNNode,
        view: SCNView
    ) {
        guard let selectedJointWorldPosition else {
            root.isHidden = true
            return
        }

        root.isHidden = false
        root.simdPosition = selectedJointWorldPosition

        screenRing.simdOrientation = simd_inverse(root.simdWorldOrientation) * cameraNode.simdWorldOrientation

        let cameraPos = cameraNode.simdWorldPosition
        let distance = max(simd_length(selectedJointWorldPosition - cameraPos), 0.001)

        let fov = Float(cameraNode.camera?.fieldOfView ?? 69.4) * .pi / 180.0
        let worldHeightAtDepth = 2.0 * distance * tan(fov * 0.5)
        let pixelHeight = max(Float(view.bounds.height), 1.0)

        let desiredPixels: Float = 120.0
        let worldDiameter = worldHeightAtDepth * desiredPixels / pixelHeight
        let worldRadius = worldDiameter * 0.5

        root.simdScale = SIMD3<Float>(repeating: worldRadius / Float(radius))
    }

    func axisFromHitNode(_ node: SCNNode?) -> Axis? {
        var n = node

        while let current = n {
            switch current.name {
            case xRing.name:
                return .x
            case yRing.name:
                return .y
            case zRing.name:
                return .z
            case screenRing.name:
                return .screen
            default:
                n = current.parent
            }
        }

        return nil
    }

    private func makeRingGeometry(color: NSColor) -> SCNGeometry {
        let torus = SCNTorus(
            ringRadius: radius,
            pipeRadius: 0.006
        )

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false

        torus.materials = [material]
        return torus
    }
}
