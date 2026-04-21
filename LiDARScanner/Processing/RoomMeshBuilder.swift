import Foundation
import RoomPlan
import ARKit
import simd

/// Converts a RoomPlan CapturedRoom into an AggregatedMesh for texture baking.
///
/// Used when ARMeshAnchors are unavailable (RoomCaptureSession does not surface them
/// through frame.anchors). Each Surface becomes a quad; each Object becomes a box.
/// The resulting mesh is simpler than a raw LiDAR scan but geometrically accurate.
enum RoomMeshBuilder {

    static func build(from room: CapturedRoom) -> AggregatedMesh {
        var vertices:          [SIMD3<Float>]             = []
        var faces:             [[UInt32]]                 = []
        var normals:           [SIMD3<Float>]             = []
        var vertexAnchorIndex: [Int]                      = []
        var anchorVertexRanges:[(start: Int, count: Int)] = []
        var anchorIdx = 0

        // All flat surfaces: walls, floors, ceilings, doors, windows, openings
        let surfaces = room.walls + room.floors + room.ceilings
                     + room.doors + room.windows + room.openings

        for surface in surfaces {
            let start = vertices.count
            addQuad(
                width:     surface.dimensions.x,
                height:    surface.dimensions.y,
                transform: surface.transform,
                anchorIdx: anchorIdx,
                vertices:  &vertices, normals: &normals,
                faces:     &faces, vertexAnchorIndex: &vertexAnchorIndex
            )
            anchorVertexRanges.append((start: start, count: vertices.count - start))
            anchorIdx += 1
        }

        // Objects (furniture, appliances, etc.) as boxes
        for object in room.objects {
            let start = vertices.count
            addBox(
                dimensions: object.dimensions,
                transform:  object.transform,
                anchorIdx:  anchorIdx,
                vertices:   &vertices, normals: &normals,
                faces:      &faces, vertexAnchorIndex: &vertexAnchorIndex
            )
            anchorVertexRanges.append((start: start, count: vertices.count - start))
            anchorIdx += 1
        }

        return AggregatedMesh(
            vertices:           vertices,
            faces:              faces,
            normals:            normals,
            vertexAnchorIndex:  vertexAnchorIndex,
            anchorCount:        anchorIdx,
            anchorVertexRanges: anchorVertexRanges
        )
    }

    // MARK: - Geometry helpers

    /// Generates a two-triangle quad lying in the local XY plane, with +Z as the normal.
    private static func addQuad(
        width: Float, height: Float,
        transform: simd_float4x4,
        anchorIdx: Int,
        vertices:  inout [SIMD3<Float>],
        normals:   inout [SIMD3<Float>],
        faces:     inout [[UInt32]],
        vertexAnchorIndex: inout [Int]
    ) {
        let hw = width  / 2
        let hh = height / 2

        let local: [SIMD3<Float>] = [
            SIMD3(-hw, -hh, 0),
            SIMD3( hw, -hh, 0),
            SIMD3( hw,  hh, 0),
            SIMD3(-hw,  hh, 0),
        ]

        let worldVerts  = local.map { transform.act($0) }
        let worldNormal = simd_normalize(transform.rotateOnly(SIMD3(0, 0, 1)))

        let base = UInt32(vertices.count)
        vertices          += worldVerts
        normals           += Array(repeating: worldNormal, count: 4)
        vertexAnchorIndex += Array(repeating: anchorIdx,   count: 4)

        faces.append([base,   base+1, base+2])
        faces.append([base,   base+2, base+3])
    }

    /// Generates a six-faced box with the given half-extents and world transform.
    private static func addBox(
        dimensions: SIMD3<Float>,
        transform:  simd_float4x4,
        anchorIdx:  Int,
        vertices:   inout [SIMD3<Float>],
        normals:    inout [SIMD3<Float>],
        faces:      inout [[UInt32]],
        vertexAnchorIndex: inout [Int]
    ) {
        let hw = dimensions.x / 2
        let hh = dimensions.y / 2
        let hd = dimensions.z / 2

        // (local quad vertices, local outward normal)
        let boxFaces: [([SIMD3<Float>], SIMD3<Float>)] = [
            ([ SIMD3(-hw,-hh, hd), SIMD3( hw,-hh, hd), SIMD3( hw, hh, hd), SIMD3(-hw, hh, hd) ], SIMD3( 0, 0, 1)),
            ([ SIMD3( hw,-hh,-hd), SIMD3(-hw,-hh,-hd), SIMD3(-hw, hh,-hd), SIMD3( hw, hh,-hd) ], SIMD3( 0, 0,-1)),
            ([ SIMD3(-hw,-hh,-hd), SIMD3(-hw,-hh, hd), SIMD3(-hw, hh, hd), SIMD3(-hw, hh,-hd) ], SIMD3(-1, 0, 0)),
            ([ SIMD3( hw,-hh, hd), SIMD3( hw,-hh,-hd), SIMD3( hw, hh,-hd), SIMD3( hw, hh, hd) ], SIMD3( 1, 0, 0)),
            ([ SIMD3(-hw, hh, hd), SIMD3( hw, hh, hd), SIMD3( hw, hh,-hd), SIMD3(-hw, hh,-hd) ], SIMD3( 0, 1, 0)),
            ([ SIMD3(-hw,-hh,-hd), SIMD3( hw,-hh,-hd), SIMD3( hw,-hh, hd), SIMD3(-hw,-hh, hd) ], SIMD3( 0,-1, 0)),
        ]

        for (localVerts, localNormal) in boxFaces {
            let base        = UInt32(vertices.count)
            let worldVerts  = localVerts.map { transform.act($0) }
            let worldNormal = simd_normalize(transform.rotateOnly(localNormal))

            vertices          += worldVerts
            normals           += Array(repeating: worldNormal, count: 4)
            vertexAnchorIndex += Array(repeating: anchorIdx,   count: 4)

            faces.append([base,   base+1, base+2])
            faces.append([base,   base+2, base+3])
        }
    }
}

// MARK: - simd_float4x4 helpers

private extension simd_float4x4 {
    /// Transforms a point (w=1).
    func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4<Float>(v.x, v.y, v.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Rotates a direction vector (w=0), strips translation.
    func rotateOnly(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4<Float>(v.x, v.y, v.z, 0)
        return SIMD3<Float>(r.x, r.y, r.z)
    }
}
