import AppKit
import SceneKit
import SwiftUI

struct OrthographicRigOverlayView: NSViewRepresentable {
    let importedRigScene: ImportedRigScene?
    let opacity: CGFloat
    let overlayScale: Double
    let overlayOffsetX: Double
    let overlayOffsetY: Double

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard let importedRigScene else {
            view.scene = nil
            return
        }

        view.scene = importedRigScene.scene
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        importedRigScene.scene.background.contents = NSColor.clear

        importedRigScene.rootNode.scale = SCNVector3(
            Float(overlayScale),
            Float(overlayScale),
            Float(overlayScale)
        )
        importedRigScene.rootNode.position.x = CGFloat(overlayOffsetX)
        importedRigScene.rootNode.position.y = CGFloat(overlayOffsetY)

        USDZRigSceneLoader.applyTransparency(
            rootNode: importedRigScene.rootNode,
            opacity: opacity
        )

        ensureOrthographicCamera(
            view: view,
            scene: importedRigScene.scene
        )
    }

    private func ensureOrthographicCamera(
        view: SCNView,
        scene: SCNScene
    ) {
        let cameraNode: SCNNode

        if let existing = scene.rootNode.childNode(
            withName: "GravitasRotoMotionOrthoCamera",
            recursively: true
        ) {
            cameraNode = existing
        } else {
            let node = SCNNode()
            node.name = "GravitasRotoMotionOrthoCamera"
            node.camera = SCNCamera()
            scene.rootNode.addChildNode(node)
            cameraNode = node
        }

        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 2.4
        cameraNode.position = SCNVector3(0, 1.2, 5.0)
        cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        cameraNode.look(at: SCNVector3(0, 1.2, 0))

        view.pointOfView = cameraNode

        ensureLights(scene: scene)
    }

    private func ensureLights(scene: SCNScene) {
        if scene.rootNode.childNode(withName: "GravitasRotoMotionAmbient", recursively: true) == nil {
            let ambient = SCNNode()
            ambient.name = "GravitasRotoMotionAmbient"
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 700
            scene.rootNode.addChildNode(ambient)
        }

        if scene.rootNode.childNode(withName: "GravitasRotoMotionKey", recursively: true) == nil {
            let key = SCNNode()
            key.name = "GravitasRotoMotionKey"
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
            scene.rootNode.addChildNode(key)
        }
    }
}
