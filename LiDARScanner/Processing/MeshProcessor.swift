import Foundation
import ARKit
import RoomPlan

@MainActor
class MeshProcessor: ObservableObject {
    @Published var progress: Float = 0
    @Published var statusMessage: String = "Finalizing geometry..."

    func process(
        meshAnchors: [ARMeshAnchor],
        keyFrames: [CapturedKeyFrame],
        capturedRoom: CapturedRoom? = nil,
        duration: TimeInterval
    ) async throws -> Scan {

        setStatus("Finalizing geometry...", progress: 0.05)

        let aggregatedMesh: AggregatedMesh
        if !meshAnchors.isEmpty {
            // Standard path: aggregate raw LiDAR mesh anchors.
            aggregatedMesh = try await Task.detached(priority: .userInitiated) {
                try MeshAggregator.aggregate(meshAnchors: meshAnchors)
            }.value
        } else if let room = capturedRoom {
            // RoomPlan path: ARMeshAnchors are not exposed by RoomCaptureSession.
            // Build geometry from the parametric CapturedRoom surfaces and objects.
            setStatus("Building room geometry...", progress: 0.05)
            aggregatedMesh = RoomMeshBuilder.build(from: room)
            guard !aggregatedMesh.vertices.isEmpty else { throw MeshError.noMeshData }
        } else {
            throw MeshError.noMeshData
        }

        setStatus("Baking textures...", progress: 0.35)

        let bakedMesh = try await Task.detached(priority: .userInitiated) {
            try TextureBaker.bake(mesh: aggregatedMesh, keyFrames: keyFrames)
        }.value

        setStatus("Preparing your scan...", progress: 0.70)

        // Exporter uses UIKit (SCNView snapshot) so it must run on the main actor.
        let scan = try Exporter.export(
            bakedMesh: bakedMesh,
            capturedRoom: capturedRoom,
            duration: duration
        )

        setStatus("Done!", progress: 1.0)
        return scan
    }

    private func setStatus(_ message: String, progress: Float) {
        statusMessage = message
        self.progress = progress
    }
}
