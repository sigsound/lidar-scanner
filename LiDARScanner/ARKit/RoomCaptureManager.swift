import Foundation
import RoomPlan
import ARKit

/// Manages RoomCaptureSession state and publishes detected room elements.
/// The session itself is owned by RoomCaptureView; call configure(captureSession:)
/// once the view is ready, then start()/stop() as needed.
@MainActor
final class RoomCaptureManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var detectedWalls: Int   = 0
    @Published var detectedObjects: Int = 0

    // MARK: - Internal

    private(set) var captureSession: RoomCaptureSession?
    private var latestRoom: CapturedRoom?
    private var stopContinuation: CheckedContinuation<CapturedRoom?, Never>?

    /// The ARSession owned by RoomCaptureView — read-only access for mesh anchors.
    var arSession: ARSession? { captureSession?.arSession }

    // MARK: - Setup

    /// Called from RoomScanContainer once RoomCaptureView exists.
    func configure(captureSession: RoomCaptureSession) {
        self.captureSession = captureSession
        captureSession.delegate = self
    }

    // MARK: - Control

    func start() {
        captureSession?.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Stops the session and returns the final CapturedRoom.
    /// Includes a 5-second timeout so a hung session never blocks the UI.
    func stop() async -> CapturedRoom? {
        guard let captureSession else { return latestRoom }
        return await withCheckedContinuation { [weak self] continuation in
            self?.stopContinuation = continuation
            captureSession.stop()

            // Safety net: resume with the last incremental room if didEndWith is late.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let pending = self.stopContinuation else { return }
                self.stopContinuation = nil
                pending.resume(returning: self.latestRoom)
            }
        }
    }

    /// Resets state and restarts a fresh scan — used by the Rescan flow.
    func restart() {
        stopContinuation?.resume(returning: nil)
        stopContinuation = nil
        detectedWalls   = 0
        detectedObjects = 0
        latestRoom      = nil
        captureSession?.run(configuration: RoomCaptureSession.Configuration())
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
            self?.latestRoom      = room
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
            self?.latestRoom      = room
            self?.stopContinuation?.resume(returning: error == nil ? room : self?.latestRoom)
            self?.stopContinuation = nil
        }
    }
}
