import Foundation
import ARKit
import UIKit
import simd

/// The result of the texture baking pass.
/// Vertices have been expanded to 3 unique vertices per face so each triangle
/// can carry its own UV coordinates without discontinuities caused by per-vertex
/// frame assignment crossing tile boundaries.
struct BakedMesh: @unchecked Sendable {
    /// Expanded vertex positions — one triple per original face.
    let vertices: [SIMD3<Float>]
    /// Expanded per-vertex normals.
    let normals: [SIMD3<Float>]
    /// Expanded per-vertex UV coordinates in atlas space.
    let uvCoords: [SIMD2<Float>]
    /// Number of original triangles (= vertices.count / 3).
    let faceCount: Int
    /// The texture atlas image.
    let atlasImage: UIImage

    /// Sequential face index buffer: face i uses [3i, 3i+1, 3i+2].
    var faces: [[UInt32]] {
        (0..<faceCount).map { i in
            let b = UInt32(i * 3)
            return [b, b + 1, b + 2]
        }
    }
}

/// Bakes photographic texture from captured key frames onto the aggregated mesh.
///
/// Strategy: **per-face frame selection with vertex expansion.**
/// For each triangle, we find the best key frame where all three vertices
/// project within the image bounds. The three vertices are then duplicated
/// (expanded) so each face owns its own UV coordinates — eliminating the UV
/// discontinuities that arise when adjacent faces share a vertex but map to
/// different atlas tiles.
enum TextureBaker {

    static let atlasSize = 2048

    static func bake(
        mesh: AggregatedMesh,
        keyFrames: [CapturedKeyFrame]
    ) throws -> BakedMesh {
        guard !keyFrames.isEmpty else {
            return makeGrayMesh(from: mesh)
        }

        let numFrames = keyFrames.count
        let tilesPerRow = max(1, Int(ceil(sqrt(Double(numFrames)))))
        let tileSizeUV = 1.0 / Float(tilesPerRow)

        var expVerts   = [SIMD3<Float>]();  expVerts.reserveCapacity(mesh.faces.count * 3)
        var expNormals = [SIMD3<Float>]();  expNormals.reserveCapacity(mesh.faces.count * 3)
        var expUVs     = [SIMD2<Float>]();  expUVs.reserveCapacity(mesh.faces.count * 3)

        for face in mesh.faces {
            guard face.count == 3 else { continue }

            let v0 = mesh.vertices[Int(face[0])];  let n0 = mesh.normals[Int(face[0])]
            let v1 = mesh.vertices[Int(face[1])];  let n1 = mesh.normals[Int(face[1])]
            let v2 = mesh.vertices[Int(face[2])];  let n2 = mesh.normals[Int(face[2])]

            let centroid = (v0 + v1 + v2) / 3
            // Average vertex normal — used to reject frames where the face is back-facing.
            let faceNormal = simd_normalize((n0 + n1 + n2) / 3)

            // Find the best key frame where all three vertices are in-frame.
            let frameIdx = bestFrameIndex(
                for: centroid,
                faceNormal: faceNormal,
                v0: v0, v1: v1, v2: v2,
                in: keyFrames
            )

            let frame   = keyFrames[frameIdx]
            let imgW    = Float(frame.imageResolution.width)
            let imgH    = Float(frame.imageResolution.height)
            let tileCol = frameIdx % tilesPerRow
            let tileRow = frameIdx / tilesPerRow
            let tileU   = Float(tileCol) * tileSizeUV
            let tileV   = Float(tileRow) * tileSizeUV

            expVerts   += [v0, v1, v2]
            expNormals += [n0, n1, n2]
            expUVs     += [
                projectToAtlasUV(v0, frame: frame, tileU: tileU, tileV: tileV, tileSize: tileSizeUV, imgW: imgW, imgH: imgH),
                projectToAtlasUV(v1, frame: frame, tileU: tileU, tileV: tileV, tileSize: tileSizeUV, imgW: imgW, imgH: imgH),
                projectToAtlasUV(v2, frame: frame, tileU: tileU, tileV: tileV, tileSize: tileSizeUV, imgW: imgW, imgH: imgH),
            ]
        }

        let atlas = renderAtlas(keyFrames: keyFrames, tilesPerRow: tilesPerRow)

        return BakedMesh(
            vertices:   expVerts,
            normals:    expNormals,
            uvCoords:   expUVs,
            faceCount:  expVerts.count / 3,
            atlasImage: atlas
        )
    }

    // MARK: - Core helpers

    /// Selects the index of the best key frame for a triangle, requiring that:
    ///   1. The face normal faces toward the camera (prevents back-projection ghosting).
    ///   2. All three projected vertices fall within the image bounds (+ 8% margin).
    /// Falls back to the best-scoring frame if none fully satisfies both criteria.
    private static func bestFrameIndex(
        for centroid: SIMD3<Float>,
        faceNormal: SIMD3<Float>,
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>,
        in keyFrames: [CapturedKeyFrame]
    ) -> Int {
        var bestFull    = Float(-1); var bestFullIdx    = -1
        var bestPartial = Float(-1); var bestPartialIdx = -1
        var bestAny     = Float(-1); var bestAnyIdx     = 0

        for (idx, frame) in keyFrames.enumerated() {
            let score = alignmentScore(for: centroid, frame: frame)
            if score > bestAny { bestAny = score; bestAnyIdx = idx }
            guard score > 0.05 else { continue }

            // Reject frames where the face is back-facing or nearly edge-on.
            // dot(faceNormal, camToFace) < 0 means the face points toward the camera.
            let camPos = SIMD3<Float>(frame.cameraTransform.columns.3.x,
                                     frame.cameraTransform.columns.3.y,
                                     frame.cameraTransform.columns.3.z)
            let camToFace = simd_normalize(centroid - camPos)
            guard simd_dot(faceNormal, camToFace) < 0.2 else { continue }

            if score > bestPartial {
                bestPartial    = score
                bestPartialIdx = idx
            }

            let imgW = Double(frame.imageResolution.width)
            let imgH = Double(frame.imageResolution.height)

            guard
                inBounds(project(v0, through: frame), w: imgW, h: imgH),
                inBounds(project(v1, through: frame), w: imgW, h: imgH),
                inBounds(project(v2, through: frame), w: imgW, h: imgH)
            else { continue }

            if score > bestFull {
                bestFull    = score
                bestFullIdx = idx
            }
        }

        if bestFullIdx    >= 0 { return bestFullIdx }
        if bestPartialIdx >= 0 { return bestPartialIdx }
        return bestAnyIdx
    }

    /// Alignment score for a world-space point relative to a camera frame.
    /// Returns a value > 0 if the point is in front of the camera.
    private static func alignmentScore(
        for worldPoint: SIMD3<Float>,
        frame: CapturedKeyFrame
    ) -> Float {
        let camPos = SIMD3<Float>(
            frame.cameraTransform.columns.3.x,
            frame.cameraTransform.columns.3.y,
            frame.cameraTransform.columns.3.z
        )
        let camForward = SIMD3<Float>(
            -frame.cameraTransform.columns.2.x,
            -frame.cameraTransform.columns.2.y,
            -frame.cameraTransform.columns.2.z
        )
        let toPoint = worldPoint - camPos
        let distance = simd_length(toPoint)
        guard distance > 0.01 else { return 0 }

        let alignment = simd_dot(simd_normalize(camForward), simd_normalize(toPoint))
        guard alignment > 0.05 else { return 0 }

        return alignment / (1 + distance * 0.25)   // stronger distance penalty vs old 0.12
    }

    /// Projects a world-space point and converts to atlas UV within a tile.
    private static func projectToAtlasUV(
        _ worldPoint: SIMD3<Float>,
        frame: CapturedKeyFrame,
        tileU: Float,
        tileV: Float,
        tileSize: Float,
        imgW: Float,
        imgH: Float
    ) -> SIMD2<Float> {
        let p = project(worldPoint, through: frame)
        let normX = min(max(Float(p.x) / imgW, 0), 1)
        let normY = min(max(Float(p.y) / imgH, 0), 1)
        return SIMD2<Float>(tileU + normX * tileSize, tileV + normY * tileSize)
    }

    /// Projects a world-space point through the camera intrinsics of a key frame.
    /// ARKit: camera looks down -Z, +Y is up.
    /// Image coords: origin top-left, +y downward → must negate camera Y.
    static func project(_ worldPoint: SIMD3<Float>, through frame: CapturedKeyFrame) -> CGPoint {
        let worldToCamera = frame.cameraTransform.inverse
        let p4 = worldToCamera * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        guard p4.z < 0 else { return CGPoint(x: -1, y: -1) }

        let m  = frame.intrinsics
        let fx = m[0][0];  let fy = m[1][1]
        let cx = m[2][0];  let cy = m[2][1]
        let depth = -p4.z

        return CGPoint(
            x: Double(fx * (p4.x / depth) + cx),
            y: Double(-fy * (p4.y / depth) + cy)   // negate Y: camera +Y up ↔ image +y down
        )
    }

    /// Returns true if the projected point falls within the image bounds,
    /// with a small inset margin so edge-grazing vertices are excluded.
    private static func inBounds(_ p: CGPoint, w: Double, h: Double) -> Bool {
        let margin = 0.08  // 8% inset — wider margin avoids distorted edge projections
        return p.x >= w * margin  && p.x <= w * (1 - margin)
            && p.y >= h * margin  && p.y <= h * (1 - margin)
    }

    // MARK: - Atlas rendering

    /// Draws one key-frame image per tile (one tile per key frame).
    private static func renderAtlas(
        keyFrames: [CapturedKeyFrame],
        tilesPerRow: Int
    ) -> UIImage {
        let tileSize = atlasSize / tilesPerRow
        let canvasSize = CGSize(width: atlasSize, height: atlasSize)

        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { _ in
            UIColor.gray.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvasSize))

            for (idx, frame) in keyFrames.enumerated() {
                let col = idx % tilesPerRow
                let row = idx / tilesPerRow
                let rect = CGRect(x: col * tileSize, y: row * tileSize,
                                  width: tileSize,  height: tileSize)
                frame.image.draw(in: rect)
            }
        }
    }

    // MARK: - Fallback for empty key-frame list

    private static func makeGrayMesh(from mesh: AggregatedMesh) -> BakedMesh {
        var expVerts   = [SIMD3<Float>]()
        var expNormals = [SIMD3<Float>]()
        let neutralUV  = SIMD2<Float>(0.5, 0.5)

        for face in mesh.faces where face.count == 3 {
            expVerts   += [mesh.vertices[Int(face[0])], mesh.vertices[Int(face[1])], mesh.vertices[Int(face[2])]]
            expNormals += [mesh.normals[Int(face[0])],  mesh.normals[Int(face[1])],  mesh.normals[Int(face[2])]]
        }

        let grayImage = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return BakedMesh(
            vertices:   expVerts,
            normals:    expNormals,
            uvCoords:   Array(repeating: neutralUV, count: expVerts.count),
            faceCount:  expVerts.count / 3,
            atlasImage: grayImage
        )
    }
}
