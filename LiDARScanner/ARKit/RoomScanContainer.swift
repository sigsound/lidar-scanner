import SwiftUI
import RoomPlan
import ARKit
import SceneKit

/// Wraps a RoomCaptureView (camera feed + parametric room overlay) with a transparent
/// SCNView on top for the colored point cloud.
///
/// RoomCaptureView owns the ARSession exclusively — we never hand it to ARSCNView,
/// which was the source of session-delegate conflicts in the previous approach.
/// The point cloud reads `arSession.currentFrame` directly in the SCN render loop.
struct RoomScanContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let roomCaptureManager: RoomCaptureManager
    @Binding var showCamera: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = UIColor(white: 0.05, alpha: 1)

        // Layer 1 — RoomCaptureView: camera feed + live parametric room overlay
        let roomView = context.coordinator.roomCaptureView
        roomView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(roomView)
        pin(roomView, to: container)

        // Layer 2 — SCNView: transparent overlay for the colored point cloud
        let scnView = context.coordinator.scnView
        scnView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scnView)
        pin(scnView, to: container)

        // Wire managers to RoomCaptureView's session, then start scanning.
        // Must run on MainActor; makeUIView is called on the main thread so this
        // Task executes before the very next run-loop pass.
        Task { @MainActor in
            roomCaptureManager.configure(captureSession: roomView.captureSession)
            if let arSession = roomCaptureManager.arSession {
                sessionManager.attachSession(arSession)
            }
            roomCaptureManager.start()
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Hiding RoomCaptureView reveals the dark container background,
        // giving the point cloud a clean dark canvas.
        context.coordinator.roomCaptureView.isHidden = !showCamera
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    private func pin(_ view: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, SCNSceneRendererDelegate {

        let roomCaptureView = RoomCaptureView(frame: .zero)
        let scnView: SCNView
        let pointCloudNode = PointCloudNode()

        private weak var sessionManager: ARSessionManager?
        private var frameCounter = 0
        private let rebuildStride = 4   // ~15 fps point cloud refresh at 60 Hz

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager

            // Build the SCNView here so it's ready before makeUIView adds it.
            scnView = SCNView(frame: .zero)
            super.init()

            scnView.backgroundColor = .clear          // transparent over camera feed
            scnView.showsStatistics  = false
            scnView.antialiasingMode = .none
            scnView.preferredFramesPerSecond = 30

            let scene = SCNScene()
            scene.background.contents = UIColor.clear  // SceneKit background also clear
            scene.rootNode.addChildNode(pointCloudNode)
            scnView.scene    = scene
            scnView.delegate = self
            scnView.isPlaying = true   // keep render loop alive without ARKit driving it
        }

        // Called by SCNView's own timer (~30 fps). RoomCaptureView owns the session;
        // we read currentFrame without touching the delegate.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            frameCounter += 1
            guard frameCounter % rebuildStride == 0 else { return }

            let arSession = roomCaptureView.captureSession.arSession
            guard let frame = arSession.currentFrame else { return }

            // Forward every throttled frame — drives guidance, warnings, key-frame capture.
            Task { @MainActor [weak sessionManager] in
                sessionManager?.didUpdate(frame: frame)
            }

            // Point cloud only once mesh anchors are present.
            let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            guard !anchors.isEmpty else { return }
            pointCloudNode.update(anchors: anchors, frame: frame)
        }
    }
}
