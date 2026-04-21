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
    /// Most recent set of ARMeshAnchors seen in any frame — snapshotted while session is live.
    private(set) var latestMeshAnchors: [ARMeshAnchor] = []

    // Strong reference to the delegate adapter — ARSession.delegate is weak,
    // so without this the adapter is immediately deallocated after setSession().
    private var delegateAdapter: SessionDelegateAdapter?

    private var frameCaptureCounter = 0
    private let keyFrameInterval = 30   // ~1 fps at 30 fps
    private let maxKeyFrames = 60

    // Shared CPU-based CIContext for background pixel buffer conversion.
    // Software renderer avoids conflicts with ARKit's Metal pipeline.
    private static let conversionContext = CIContext(options: [.useSoftwareRenderer: true])

    /// Clears captured data and restarts the AR session.
    /// Only restarts if this manager owns the session (standalone ARKit mode).
    func reset() {
        clearCaptureState()
        guard delegateAdapter != nil else { return }   // externally-owned session — don't restart
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        }
        session?.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Clears all captured data without touching the session — used when the session
    /// is externally owned (e.g. by RoomCaptureSession).
    func clearCaptureState() {
        capturedKeyFrames  = []
        capturedFrameCount = 0
        meshCoverage       = 0
        frameCaptureCounter = 0
        guidance           = .initial
        activeWarning      = nil
        latestMeshAnchors  = []
    }

    /// Attaches an externally-owned ARSession (e.g. from RoomCaptureSession) without
    /// overriding its delegate. Key-frame capture is driven by the ARSCNView render loop.
    func attachSession(_ session: ARSession) {
        self.session = session
        // delegateAdapter intentionally left nil — we do not own this session
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
        // Keep a running snapshot of mesh anchors so stopScan() can read them
        // before the session stops (currentFrame anchors may clear on session end).
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !anchors.isEmpty {
            latestMeshAnchors = anchors
        }
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
        // In RoomPlan mode, mesh anchor count may stay low; the caller can
        // override this via updateCoverage(roomElements:) below.
        if count > 0 {
            meshCoverage = min(Float(count) / 30.0, 1.0)
        }
    }

    /// Called by ScanSessionView to blend RoomPlan detection counts into coverage
    /// when raw ARMeshAnchors are sparse (RoomPlan session mode).
    func updateCoverage(walls: Int, objects: Int) {
        // Treat 8+ surfaces as "sufficient" coverage (walls + objects combined)
        let total = walls + objects
        let roomCoverage = min(Float(total) / 8.0, 1.0)
        meshCoverage = max(meshCoverage, roomCoverage)
        updateGuidance()
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
