import Foundation
import ARKit
import CoreImage
import UIKit

enum ScanWarning: String, Equatable {
    case movingTooFast = "Slow down for better quality"
    case lowLight = "Improve lighting for better results"
}

enum ScanGuidance: String {
    case initial = "Slowly move your camera around the room"
    case goodCoverage = "Keep going — cover walls, floor, and ceiling"
    case sufficient = "Looking good. Tap Stop when ready."
}

/// A key frame captured during scanning. Pre-converted to UIImage so the
/// CVPixelBuffer from ARKit can be released back to the buffer pool.
struct CapturedKeyFrame: @unchecked Sendable {
    let image: UIImage
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
}

/// Manages ARSession state and key-frame capture.
@MainActor
class ARSessionManager: ObservableObject {
    @Published var meshCoverage: Float = 0
    @Published var trackingState: ARCamera.TrackingState = .notAvailable
    @Published var activeWarning: ScanWarning?
    @Published var guidance: ScanGuidance = .initial
    @Published var capturedFrameCount: Int = 0

    private(set) var session: ARSession?
    private(set) var capturedKeyFrames: [CapturedKeyFrame] = []

    // Strong reference to the delegate adapter — ARSession.delegate is weak,
    // so without this the adapter is immediately deallocated after setSession().
    private var delegateAdapter: SessionDelegateAdapter?

    private var frameCaptureCounter = 0
    private let keyFrameInterval = 30   // ~1 fps at 30 fps
    private let maxKeyFrames = 60

    // Shared CPU-based CIContext for background pixel buffer conversion.
    // Software renderer avoids conflicts with ARKit's Metal pipeline.
    private static let conversionContext = CIContext(options: [.useSoftwareRenderer: true])

    /// Clears all captured data and restarts the AR session for a fresh scan.
    func reset() {
        capturedKeyFrames = []
        capturedFrameCount = 0
        meshCoverage = 0
        frameCaptureCounter = 0
        guidance = .initial
        activeWarning = nil

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        session?.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func setSession(_ session: ARSession) {
        self.session = session
        let adapter = SessionDelegateAdapter(manager: self)
        self.delegateAdapter = adapter   // retain strongly; session.delegate is weak
        session.delegate = adapter
    }

    // MARK: - Called by delegate adapter (on main actor)

    func didUpdate(frame: ARFrame) {
        trackingState = frame.camera.trackingState
        updateWarnings(frame: frame)
        captureKeyFrameIfNeeded(frame: frame)
        updateMeshCoverage(frame: frame)
        updateGuidance()
    }

    // MARK: - Private helpers

    private func updateWarnings(frame: ARFrame) {
        var warning: ScanWarning?
        if case .limited(.excessiveMotion) = frame.camera.trackingState {
            warning = .movingTooFast
        }
        if let lightEstimate = frame.lightEstimate, lightEstimate.ambientIntensity < 150 {
            warning = .lowLight
        }
        activeWarning = warning
    }

    private func captureKeyFrameIfNeeded(frame: ARFrame) {
        frameCaptureCounter += 1
        guard frameCaptureCounter >= keyFrameInterval else { return }
        frameCaptureCounter = 0

        // Snapshot the metadata we need from this frame right now on the main thread.
        let cameraTransform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        // Retain the pixel buffer explicitly so it survives the async hop.
        // ARKit won't reuse this specific CVPixelBuffer object while we hold a reference.
        let pixelBuffer = frame.capturedImage

        // Convert on a background thread to avoid blocking the main thread
        // and to sidestep Metal context conflicts with ARKit's renderer.
        Task.detached(priority: .utility) { [weak self] in
            guard let image = Self.convertPixelBuffer(pixelBuffer) else { return }
            let keyFrame = CapturedKeyFrame(
                image: image,
                cameraTransform: cameraTransform,
                intrinsics: intrinsics,
                imageResolution: imageResolution
            )
            await MainActor.run {
                self?.storeKeyFrame(keyFrame)
            }
        }
    }

    private func storeKeyFrame(_ keyFrame: CapturedKeyFrame) {
        if capturedKeyFrames.count < maxKeyFrames {
            capturedKeyFrames.append(keyFrame)
        } else {
            let idx = Int.random(in: 0..<capturedKeyFrames.count)
            capturedKeyFrames[idx] = keyFrame
        }
        capturedFrameCount = capturedKeyFrames.count
    }

    private nonisolated static func convertPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        // Lock for read-only access before handing to CIImage.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = conversionContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func updateMeshCoverage(frame: ARFrame) {
        let count = frame.anchors.filter { $0 is ARMeshAnchor }.count
        meshCoverage = min(Float(count) / 30.0, 1.0)
    }

    private func updateGuidance() {
        if meshCoverage > 0.8 {
            guidance = .sufficient
        } else if meshCoverage > 0.35 {
            guidance = .goodCoverage
        } else {
            guidance = .initial
        }
    }
}

// MARK: - Delegate Bridge

private class SessionDelegateAdapter: NSObject, ARSessionDelegate {
    weak var manager: ARSessionManager?

    init(manager: ARSessionManager) {
        self.manager = manager
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let manager = manager
        Task { @MainActor in
            manager?.didUpdate(frame: frame)
        }
    }
}
