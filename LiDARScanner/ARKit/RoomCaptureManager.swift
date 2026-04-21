import Foundation
import RoomPlan
import ARKit

/// Wraps RoomCaptureSession and publishes incremental room data during scanning.
/// Exposes the session's underlying ARSession so it can be shared with ARSCNView.
@MainActor
final class RoomCaptureManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var detectedWalls: Int   = 0
    @Published var detectedObjects: Int = 0
    @Published var isCapturing: Bool    = false

    // MARK: - Internal

    private let captureSession = RoomCaptureSession()

    /// The ARSession owned by RoomPlan — assign this to ARSCNView.session.
    var arSession: ARSession { captureSession.arSession }

    private var stopContinuation: CheckedContinuation<CapturedRoom?, Never>?

    override init() {
        super.init()
        captureSession.delegate = self
    }

    // MARK: - Control

    func start() {
        let config = RoomCaptureSession.Configuration()
        isCapturing = true
        captureSession.run(configuration: config)
    }

    /// Stops the session and returns the final CapturedRoom once RoomPlan finishes processing.
    func stop() async -> CapturedRoom? {
        guard isCapturing else { return nil }
        return await withCheckedContinuation { [weak self] continuation in
            self?.stopContinuation = continuation
            self?.captureSession.stop()
        }
    }

    /// Resets all state and starts a fresh capture — used by the Rescan flow.
    func restart() {
        // Cancel any pending stop awaiter
        stopContinuation?.resume(returning: nil)
        stopContinuation = nil
        // Clear counters
        detectedWalls   = 0
        detectedObjects = 0
        isCapturing     = true
        captureSession.run(configuration: RoomCaptureSession.Configuration())
    }
}

// MARK: - RoomCaptureSessionDelegate

extension RoomCaptureManager: RoomCaptureSessionDelegate {

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didUpdate room: CapturedRoom) {
        let walls   = room.walls.count
        let objects = room.objects.count
        Task { @MainActor [weak self] in
            self?.detectedWalls   = walls
            self?.detectedObjects = objects
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                    didEndWith room: CapturedRoom,
                                    error: (any Error)?) {
        let walls   = room.walls.count
        let objects = room.objects.count
        Task { @MainActor [weak self] in
            self?.detectedWalls   = walls
            self?.detectedObjects = objects
            self?.isCapturing     = false
            self?.stopContinuation?.resume(returning: error == nil ? room : nil)
            self?.stopContinuation = nil
        }
    }
}
