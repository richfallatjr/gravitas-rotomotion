import SceneKit
import SwiftUI

struct RigSceneKitView: NSViewRepresentable {
    let importedRigScene: ImportedRigScene?
    let opacity: CGFloat
    let showModel: Bool
    let showSkeleton: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard let importedRigScene else {
            view.scene = nil
            return
        }

        if view.scene !== importedRigScene.scene {
            view.scene = importedRigScene.scene
            ensureCamera(in: importedRigScene.scene)
        }

        USDZRigSceneLoader.applyTransparency(
            rootNode: importedRigScene.rootNode,
            opacity: opacity
        )
        USDZRigSceneLoader.setModelVisibility(
            rootNode: importedRigScene.rootNode,
            visible: showModel
        )
        USDZRigSceneLoader.setSkeletonMarkers(
            rootNode: importedRigScene.rootNode,
            skeletonJointNames: importedRigScene.skeletonJointNames,
            visible: showSkeleton
        )
    }

    private func ensureCamera(in scene: SCNScene) {
        if scene.rootNode.childNode(withName: "GravitasPreviewCamera", recursively: true) != nil {
            return
        }

        let cameraNode = SCNNode()
        cameraNode.name = "GravitasPreviewCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 1.4, 4.0)
        cameraNode.eulerAngles = SCNVector3(-0.15, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNNode()
        light.name = "GravitasPreviewKeyLight"
        light.light = SCNLight()
        light.light?.type = .omni
        light.light?.intensity = 900
        light.position = SCNVector3(0, 3, 3)
        scene.rootNode.addChildNode(light)
    }
}
