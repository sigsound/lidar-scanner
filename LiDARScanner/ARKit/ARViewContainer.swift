import SwiftUI
import ARKit
import RealityKit

/// UIViewRepresentable that wraps an ARView configured for LiDAR scene reconstruction.
struct ARViewContainer: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }

        // Wireframe mesh overlay on the live camera feed
        arView.debugOptions = [.showSceneUnderstanding]

        // Disable expensive post-processing during scan
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableMotionBlur,
            .disableCameraGrain
        ]

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Hand session reference to the manager (bridged via Task to avoid sendability issues)
        let session = arView.session
        Task { @MainActor in
            sessionManager.setSession(session)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
