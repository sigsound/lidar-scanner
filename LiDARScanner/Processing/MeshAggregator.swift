import Foundation
import ARKit
import simd

/// Aggregated mesh data in world space.
struct AggregatedMesh {
    /// World-space vertex positions.
    var vertices: [SIMD3<Float>]
    /// Triangle face indices (triples into `vertices`).
    var faces: [[UInt32]]
    /// World-space per-vertex normals.
    var normals: [SIMD3<Float>]
    /// Maps global vertex index → originating anchor index (for UV atlas tiling).
    var vertexAnchorIndex: [Int]
    /// Number of anchors combined.
    var anchorCount: Int
    /// Vertex range per anchor: [(startIndex, count)].
    var anchorVertexRanges: [(start: Int, count: Int)]
}

/// Converts an array of ARMeshAnchors into a single world-space mesh.
enum MeshAggregator {

    static func aggregate(meshAnchors: [ARMeshAnchor]) throws -> AggregatedMesh {
        guard !meshAnchors.isEmpty else {
            throw MeshError.noMeshData
        }

        var allVertices: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var allNormals: [SIMD3<Float>] = []
        var vertexAnchorIndex: [Int] = []
        var anchorVertexRanges: [(start: Int, count: Int)] = []

        for (anchorIdx, anchor) in meshAnchors.enumerated() {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let rangeStart = allVertices.count

            // --- Extract vertices and transform to world space ---
            let vertexSource = geometry.vertices
            let vertexBuffer = vertexSource.buffer
            let vertexStride = vertexSource.stride
            let vertexOffset = vertexSource.offset
            let vertexCount = vertexSource.count

            // ARKit stores float3 vertices packed at 12-byte stride.
            // SIMD3<Float> requires 16-byte alignment on ARM64, so we must read
            // as three individual Floats (4-byte aligned) to avoid a misaligned load crash.
            for i in 0..<vertexCount {
                let base = vertexBuffer.contents().advanced(by: vertexOffset + i * vertexStride)
                let x = base.load(as: Float.self)
                let y = base.advanced(by: 4).load(as: Float.self)
                let z = base.advanced(by: 8).load(as: Float.self)
                let worldPos4 = transform * SIMD4<Float>(x, y, z, 1)
                allVertices.append(SIMD3<Float>(worldPos4.x, worldPos4.y, worldPos4.z))
                vertexAnchorIndex.append(anchorIdx)
            }

            // --- Extract normals and rotate to world space ---
            let normalSource = geometry.normals
            let normalBuffer = normalSource.buffer
            let normalStride = normalSource.stride
            let normalOffset = normalSource.offset
            let normalCount = normalSource.count

            // Rotation-only transform (3×3 upper-left of the anchor's 4×4 matrix)
            let rot = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            for i in 0..<normalCount {
                let base = normalBuffer.contents().advanced(by: normalOffset + i * normalStride)
                let nx = base.load(as: Float.self)
                let ny = base.advanced(by: 4).load(as: Float.self)
                let nz = base.advanced(by: 8).load(as: Float.self)
                let worldNormal = simd_normalize(rot * SIMD3<Float>(nx, ny, nz))
                allNormals.append(worldNormal)
            }

            // --- Extract faces, offset indices by current vertex base ---
            let faceElement = geometry.faces
            let faceBuffer = faceElement.buffer
            let faceCount = faceElement.count
            let indexCountPerPrimitive = faceElement.indexCountPerPrimitive // 3 for triangles
            let bytesPerIndex = faceElement.bytesPerIndex  // 4 for UInt32
            let base = UInt32(rangeStart)

            for f in 0..<faceCount {
                var face = [UInt32](repeating: 0, count: indexCountPerPrimitive)
                for j in 0..<indexCountPerPrimitive {
                    let bytePos = (f * indexCountPerPrimitive + j) * bytesPerIndex
                    let localIdx: UInt32
                    if bytesPerIndex == 2 {
                        localIdx = UInt32(faceBuffer.contents().advanced(by: bytePos).load(as: UInt16.self))
                    } else {
                        localIdx = faceBuffer.contents().advanced(by: bytePos).load(as: UInt32.self)
                    }
                    face[j] = base + localIdx
                }
                allFaces.append(face)
            }

            anchorVertexRanges.append((start: rangeStart, count: vertexCount))
        }

        return AggregatedMesh(
            vertices: allVertices,
            faces: allFaces,
            normals: allNormals,
            vertexAnchorIndex: vertexAnchorIndex,
            anchorCount: meshAnchors.count,
            anchorVertexRanges: anchorVertexRanges
        )
    }
}

enum MeshError: LocalizedError {
    case noMeshData
    case exportFailed(String)
    case thumbnailFailed

    var errorDescription: String? {
        switch self {
        case .noMeshData: return "No mesh data was captured during the scan."
        case .exportFailed(let reason): return "Export failed: \(reason)"
        case .thumbnailFailed: return "Failed to generate scan thumbnail."
        }
    }
}
