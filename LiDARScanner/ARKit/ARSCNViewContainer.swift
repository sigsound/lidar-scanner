import SwiftUI
import ARKit
import SceneKit

/// UIViewRepresentable wrapping ARSCNView for real-time point cloud rendering.
struct ARSCNViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager
    @Binding var showCamera: Bool
    /// Set to false to pause the AR session and release all point cloud geometry before processing.
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView(frame: .zero)
        scnView.automaticallyUpdatesLighting = false
        scnView.autoenablesDefaultLighting    = false
        scnView.showsStatistics               = false
        scnView.antialiasingMode              = .none

        scnView.scene.rootNode.addChildNode(context.coordinator.pointCloudNode)

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        // sceneDepth drives the live point cloud visualisation.
        // smoothedSceneDepth applies temporal filtering for cleaner colours.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics = .smoothedSceneDepth
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        }
        scnView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        scnView.delegate = context.coordinator

        let session = scnView.session
        Task { @MainActor in
            sessionManager.setSession(session)
        }

        applyBackground(to: scnView, showCamera: showCamera)
        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        applyBackground(to: uiView, showCamera: showCamera)
        if !isActive {
            uiView.session.pause()
            context.coordinator.pointCloudNode.releaseAll()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    private func applyBackground(to scnView: ARSCNView, showCamera: Bool) {
        scnView.scene.background.contents = showCamera ? nil : UIColor(white: 0.05, alpha: 1)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let pointCloudNode = PointCloudNode()
        private weak var sessionManager: ARSessionManager?
        private var frameCounter = 0
        private let sessionStride = 8   // session manager at ~4 Hz

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let scnView = renderer as? ARSCNView,
                  let arFrame = scnView.session.currentFrame else { return }

            // Point cloud: every frame — cheap when voxels are already filled.
            pointCloudNode.update(frame: arFrame, time: time)

            // Session state (key frames, guidance, mesh anchors for export): lower rate.
            frameCounter += 1
            guard frameCounter % sessionStride == 0 else { return }
            Task { @MainActor [weak sessionManager] in
                sessionManager?.didUpdate(frame: arFrame)
            }
        }
    }
}
