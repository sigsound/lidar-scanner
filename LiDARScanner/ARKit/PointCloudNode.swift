import SceneKit
import ARKit
import simd

/// Dense photographic point cloud with per-batch fade-in animation.
///
/// Points are sampled from triangle interiors (not mesh vertices), using
/// deterministic barycentric coordinates keyed to the face index so positions
/// are stable across frames. Two child nodes — stableNode (accumulated) and
/// incomingNode (fading in) — give smooth point-spray animation without
/// rebuilding the entire cloud on every anchor update.
final class PointCloudNode: SCNNode {

    // MARK: - Configuration
    private let maxPointsPerAnchor  = 1_500    // cap per ARMeshAnchor contribution
    private let maxTotalPoints      = 250_000  // GPU budget (stable + incoming)
    private let fadeInDuration      = 0.30     // seconds for a new batch to appear
    private let consolidationDelay  = 0.50     // min seconds between stable rebuilds

    // MARK: - Per-anchor state
    private var anchorFaceCounts:   [UUID: Int]            = [:]
    private var anchorTranslations: [UUID: SIMD3<Float>]   = [:]
    private var anchorPositions:    [UUID: [SIMD3<Float>]] = [:]
    private var anchorColors:       [UUID: [SIMD4<Float>]] = [:]

    // MARK: - Rendering nodes
    private let stableNode   = SCNNode()   // accumulated, always opaque
    private let incomingNode = SCNNode()   // latest batch, animating in

    // MARK: - Animation state (render-thread only)
    private var isFadingIn          = false
    private var lastConsolidateTime = TimeInterval(0)

    // MARK: - Init

    override init() {
        super.init()
        addChildNode(stableNode)
        addChildNode(incomingNode)
        incomingNode.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public update (called from render thread every frame)

    func update(anchors: [ARMeshAnchor], frame: ARFrame, time: TimeInterval) {
        // Consolidate the previous incoming batch once its fade is done.
        if isFadingIn {
            if incomingNode.opacity >= 0.99 || (time - lastConsolidateTime) >= consolidationDelay {
                consolidateIncoming(at: time)
            }
        }

        // While a batch is fading in, skip detection — anchors that changed will
        // still show as changed next cycle since their face counts are not committed yet.
        guard !isFadingIn else { return }

        var batchPositions: [SIMD3<Float>] = []
        var batchColors:    [SIMD4<Float>]  = []

        for anchor in anchors {
            guard hasChanged(anchor: anchor) else { continue }
            markSeen(anchor)

            let positions = extractInteriorPoints(from: anchor)
            let colors    = sampleColors(positions: positions, frame: frame)
            anchorPositions[anchor.identifier] = positions
            anchorColors[anchor.identifier]    = colors
            batchPositions += positions
            batchColors    += colors
        }

        guard !batchPositions.isEmpty else { return }

        setGeometry(of: incomingNode, positions: batchPositions, colors: batchColors)
        incomingNode.removeAllActions()
        incomingNode.opacity = 0
        incomingNode.runAction(.fadeIn(duration: fadeInDuration))
        isFadingIn = true
    }

    // MARK: - Change detection

    private func hasChanged(anchor: ARMeshAnchor) -> Bool {
        // New or refined mesh (ARKit adds faces as it refines the surface).
        if anchor.geometry.faces.count > (anchorFaceCounts[anchor.identifier] ?? 0) {
            return true
        }
        // Tracking correction — anchor shifted noticeably in world space.
        let t = SIMD3<Float>(anchor.transform.columns.3.x,
                             anchor.transform.columns.3.y,
                             anchor.transform.columns.3.z)
        if let prev = anchorTranslations[anchor.identifier], simd_distance(t, prev) > 0.015 {
            return true
        }
        return false
    }

    private func markSeen(_ anchor: ARMeshAnchor) {
        anchorFaceCounts[anchor.identifier]   = anchor.geometry.faces.count
        anchorTranslations[anchor.identifier] = SIMD3<Float>(anchor.transform.columns.3.x,
                                                              anchor.transform.columns.3.y,
                                                              anchor.transform.columns.3.z)
    }

    // MARK: - Consolidation

    /// Folds the incoming batch into stableNode by rebuilding from all cached data.
    private func consolidateIncoming(at time: TimeInterval) {
        incomingNode.removeAllActions()
        incomingNode.geometry = nil
        incomingNode.opacity  = 0
        isFadingIn            = false
        lastConsolidateTime   = time

        var allPositions: [SIMD3<Float>] = []
        var allColors:    [SIMD4<Float>]  = []
        for id in anchorPositions.keys {
            guard let pos = anchorPositions[id], let col = anchorColors[id] else { continue }
            allPositions += pos
            allColors    += col
        }
        if allPositions.count > maxTotalPoints {
            let step = allPositions.count / maxTotalPoints
            allPositions = Swift.stride(from: 0, to: allPositions.count, by: step).map { allPositions[$0] }
            allColors    = Swift.stride(from: 0, to: allColors.count,    by: step).map { allColors[$0] }
        }
        setGeometry(of: stableNode, positions: allPositions, colors: allColors)
    }

    // MARK: - Interior point extraction

    /// Samples one point from the interior of each face using a deterministic hash
    /// of the face index → same anchor always produces the same world positions.
    private func extractInteriorPoints(from anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let geo       = anchor.geometry
        let vSrc      = geo.vertices
        let fSrc      = geo.faces
        let faceCount = fSrc.count
        let transform = anchor.transform

        // Sub-sample step to stay inside the per-anchor cap.
        let step = max(1, faceCount / maxPointsPerAnchor)
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(min(faceCount, maxPointsPerAnchor))

        for fi in Swift.stride(from: 0, to: faceCount, by: step) {
            let (i0, i1, i2) = readFaceIndices(fSrc, at: fi)
            let lv0 = readVertex(vSrc, at: i0)
            let lv1 = readVertex(vSrc, at: i1)
            let lv2 = readVertex(vSrc, at: i2)
            let wv0 = applyTransform(lv0, transform)
            let wv1 = applyTransform(lv1, transform)
            let wv2 = applyTransform(lv2, transform)
            positions.append(interiorPoint(wv0, wv1, wv2, seed: UInt64(fi)))
        }
        return positions
    }

    // MARK: - Color sampling

    private func sampleColors(positions: [SIMD3<Float>], frame: ARFrame) -> [SIMD4<Float>] {
        let pixelBuffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let imgW = CVPixelBufferGetWidth(pixelBuffer)
        let imgH = CVPixelBufferGetHeight(pixelBuffer)

        guard let yBase    = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbCrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return Array(repeating: SIMD4<Float>(0.5, 0.5, 0.5, 1), count: positions.count)
        }

        let yRowBytes    = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbCrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let m  = frame.camera.intrinsics
        let fx = m[0][0]; let fy = m[1][1]
        let cx = m[2][0]; let cy = m[2][1]
        let worldToCamera = frame.camera.transform.inverse

        let fallback = SIMD4<Float>(0.28, 0.28, 0.28, 1)
        var colors   = [SIMD4<Float>]()
        colors.reserveCapacity(positions.count)

        for pos in positions {
            let p4 = worldToCamera * SIMD4<Float>(pos.x, pos.y, pos.z, 1)
            guard p4.z < 0 else { colors.append(fallback); continue }

            let depth = -p4.z
            let px = Int(fx * (p4.x / depth) + cx)
            let py = Int(-fy * (p4.y / depth) + cy)

            guard px >= 0, px < imgW, py >= 0, py < imgH else {
                colors.append(fallback); continue
            }

            let yVal = Float(yBase.advanced(by: py * yRowBytes + px)
                .load(as: UInt8.self)) / 255.0

            let cbCrX = px / 2; let cbCrY = py / 2
            let cbOff = cbCrY * cbCrRowBytes + cbCrX * 2
            let cb = Float(cbCrBase.advanced(by: cbOff)    .load(as: UInt8.self)) / 255.0 - 0.5
            let cr = Float(cbCrBase.advanced(by: cbOff + 1).load(as: UInt8.self)) / 255.0 - 0.5

            let r = min(max(yVal + 1.402  * cr,            0), 1)
            let g = min(max(yVal - 0.3441 * cb - 0.7141 * cr, 0), 1)
            let b = min(max(yVal + 1.772  * cb,            0), 1)
            colors.append(SIMD4<Float>(r, g, b, 1))
        }
        return colors
    }

    // MARK: - SCNGeometry construction

    private func setGeometry(of node: SCNNode, positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        guard !positions.isEmpty else { node.geometry = nil; return }

        let posData   = Data(bytes: positions, count: positions.count * MemoryLayout<SIMD3<Float>>.stride)
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let colData   = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colSource = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indices = (0..<Int32(positions.count)).map { $0 }
        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .point,
            primitiveCount: positions.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize                    = 8
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 6

        let geo = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel    = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided    = true
        geo.materials = [mat]
        node.geometry = geo
    }

    // MARK: - Low-level buffer helpers

    private func readFaceIndices(_ faces: ARGeometryElement, at fi: Int) -> (Int, Int, Int) {
        let bpi  = faces.bytesPerIndex
        let base = faces.buffer.contents().advanced(by: fi * 3 * bpi)
        if bpi == 2 {
            return (Int(base.load(as: UInt16.self)),
                    Int(base.advanced(by: 2).load(as: UInt16.self)),
                    Int(base.advanced(by: 4).load(as: UInt16.self)))
        } else {
            return (Int(base.load(as: UInt32.self)),
                    Int(base.advanced(by: 4).load(as: UInt32.self)),
                    Int(base.advanced(by: 8).load(as: UInt32.self)))
        }
    }

    private func readVertex(_ src: ARGeometrySource, at index: Int) -> SIMD3<Float> {
        let base = src.buffer.contents().advanced(by: src.offset + index * src.stride)
        return SIMD3<Float>(base.load(as: Float.self),
                            base.advanced(by: 4).load(as: Float.self),
                            base.advanced(by: 8).load(as: Float.self))
    }

    private func applyTransform(_ p: SIMD3<Float>, _ m: simd_float4x4) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    /// Returns a deterministic interior point for a triangle using the face index
    /// as an LCG seed — same face always produces the same world position.
    private func interiorPoint(
        _ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>,
        seed: UInt64
    ) -> SIMD3<Float> {
        let h1 = seed  &* 2654435761 &+ 1013904223
        let h2 = h1    &* 1664525    &+ 1013904223
        var r1 = Float(h1 & 0x7FFFFFFF) / Float(0x7FFFFFFF)
        var r2 = Float(h2 & 0x7FFFFFFF) / Float(0x7FFFFFFF)
        if r1 + r2 > 1 { r1 = 1 - r1; r2 = 1 - r2 }  // fold to triangle
        return v0 + r1 * (v1 - v0) + r2 * (v2 - v0)
    }
}
