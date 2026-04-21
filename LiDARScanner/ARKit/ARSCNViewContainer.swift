import SwiftUI
import ARKit
import SceneKit

/// UIViewRepresentable wrapping ARSCNView for real-time point cloud rendering.
/// The camera feed can be toggled on/off; the point cloud always renders.
struct ARSCNViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager
    @Binding var showCamera: Bool
    /// When provided (RoomPlan mode), this session is already running — we attach to it
    /// rather than starting our own. RoomPlan owns the session; we must not call run() on it.
    var externalARSession: ARSession? = nil

    func makeUIView(context: Context) -> ARSCNView {
        let scnView = ARSCNView(frame: .zero)
        scnView.automaticallyUpdatesLighting = true
        scnView.autoenablesDefaultLighting    = false
        scnView.showsStatistics               = false
        scnView.antialiasingMode              = .none   // save GPU during scan

        // Add the point cloud node at world origin
        scnView.scene.rootNode.addChildNode(context.coordinator.pointCloudNode)

        if let external = externalARSession {
            // RoomPlan mode: attach to the already-running session.
            // Don't call run() — RoomPlan manages the session lifecycle.
            scnView.session = external
            Task { @MainActor in
                sessionManager.attachSession(external)
            }
        } else {
            // Standalone mode: start our own session.
            let config = ARWorldTrackingConfiguration()
            config.sceneReconstruction = .meshWithClassification
            config.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            }
            scnView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            let session = scnView.session
            Task { @MainActor in
                sessionManager.setSession(session)
            }
        }

        // Register delegate (Coordinator) for render callbacks
        scnView.delegate = context.coordinator

        // Apply initial camera background
        applyBackground(to: scnView, showCamera: showCamera)

        return scnView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        applyBackground(to: uiView, showCamera: showCamera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    // MARK: - Background helpers

    private func applyBackground(to scnView: ARSCNView, showCamera: Bool) {
        if showCamera {
            // nil → ARSCNView renders the live camera feed as background
            scnView.scene.background.contents = nil
        } else {
            scnView.scene.background.contents = UIColor(white: 0.05, alpha: 1)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let pointCloudNode = PointCloudNode()
        private let sessionManager: ARSessionManager

        // Throttle point cloud rebuilds so they don't saturate the render thread.
        // Rebuild at most every N rendered frames (~15 fps at 60 fps display).
        private let rebuildStride = 4
        private var frameCounter = 0

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager
        }

        // Called on the render thread once per display refresh.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            frameCounter += 1
            guard frameCounter % rebuildStride == 0 else { return }

            guard let scnView  = renderer as? ARSCNView,
                  let arFrame  = scnView.session.currentFrame else { return }

            let anchors = arFrame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !anchors.isEmpty else { return }

            pointCloudNode.update(anchors: anchors, frame: arFrame)

            // Forward the frame to ARSessionManager (key-frame capture, coverage, etc.)
            // Must hop to MainActor since ARSessionManager is @MainActor.
            Task { @MainActor [weak sessionManager] in
                sessionManager?.didUpdate(frame: arFrame)
            }
        }
    }
}
