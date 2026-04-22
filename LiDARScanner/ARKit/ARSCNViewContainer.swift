import SwiftUI
import ARKit
import SceneKit

/// UIViewRepresentable wrapping ARSCNView for real-time point cloud rendering.
/// The camera feed can be toggled on/off; the point cloud always renders.
struct ARSCNViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager
    @Binding var showCamera: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView(frame: .zero)
        scnView.automaticallyUpdatesLighting = false  // we handle this ourselves
        scnView.autoenablesDefaultLighting    = false
        scnView.showsStatistics               = false
        scnView.antialiasingMode              = .none

        scnView.scene.rootNode.addChildNode(context.coordinator.pointCloudNode)

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        // environmentTexturing and sceneDepth are NOT used in this app.
        // Leaving them off cuts initial GPU/CPU load significantly.
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

        // Point cloud runs every frame (cheap when nothing changed).
        // Session manager (key frames, guidance) runs less often.
        private var frameCounter  = 0
        private let sessionStride = 8   // ~4 Hz at 30 Hz display

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let scnView = renderer as? ARSCNView,
                  let arFrame = scnView.session.currentFrame else { return }

            // Point cloud: every frame so fade-in animation stays smooth.
            let anchors = arFrame.anchors.compactMap { $0 as? ARMeshAnchor }
            if !anchors.isEmpty {
                pointCloudNode.update(anchors: anchors, frame: arFrame, time: time)
            }

            // Session state (key frames, coverage, guidance): lower frequency.
            frameCounter += 1
            guard frameCounter % sessionStride == 0 else { return }
            Task { @MainActor [weak sessionManager] in
                sessionManager?.didUpdate(frame: arFrame)
            }
        }
    }
}
