import SwiftUI
import RoomPlan
import ARKit
import UIKit

/// Wraps RoomCaptureView for the scan session.
///
/// RoomCaptureView uses RealityKit internally. Adding a SceneKit SCNView as an overlay
/// causes a Metal draw-validation crash (SceneKit leaves a 2D texture bound at a slot
/// RealityKit expects to hold a 1D tonemapLUT). We therefore drive key-frame capture
/// via a CADisplayLink — no second Metal renderer, no conflict.
///
/// Visual feedback during scanning comes from RoomPlan's own live parametric overlay
/// (colored planes / walls building up in real-time).
struct RoomScanContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let roomCaptureManager: RoomCaptureManager
    @Binding var showCamera: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = UIColor(white: 0.05, alpha: 1)

        let roomView = context.coordinator.roomCaptureView
        roomView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(roomView)
        pin(roomView, to: container)

        // Configure managers with RoomCaptureView's session, then start.
        Task { @MainActor in
            roomCaptureManager.configure(captureSession: roomView.captureSession)
            if let arSession = roomCaptureManager.arSession {
                sessionManager.attachSession(arSession)
            }
            roomCaptureManager.start()
        }

        // Start the Metal-free frame loop for key-frame / guidance updates.
        context.coordinator.startFrameLoop()

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
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

    final class Coordinator: NSObject {
        let roomCaptureView = RoomCaptureView(frame: .zero)
        private weak var sessionManager: ARSessionManager?
        private var displayLink: CADisplayLink?
        private var tickCount = 0
        private let captureStride = 8   // sample ~4 fps at 30 Hz display link

        init(sessionManager: ARSessionManager) {
            self.sessionManager = sessionManager
        }

        deinit { displayLink?.invalidate() }

        func startFrameLoop() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick() {
            tickCount += 1
            guard tickCount % captureStride == 0 else { return }
            guard let frame = roomCaptureView.captureSession?.arSession.currentFrame else { return }
            Task { @MainActor [weak sessionManager] in
                sessionManager?.didUpdate(frame: frame)
            }
        }
    }
}
