import SceneKit
import ARKit
import simd

/// A SceneKit node that renders an accumulative photographic point cloud.
///
/// Points are cached per ARMeshAnchor and only re-extracted when ARKit increases
/// that anchor's vertex count. Because ARKit progressively refines mesh anchors
/// (adding vertices over time), areas scanned more thoroughly accumulate more
/// points and the cloud becomes visually denser there.
final class PointCloudNode: SCNNode {

    // Maximum points to extract per anchor. Anchors with fewer vertices use all of them.
    private let maxPointsPerAnchor = 2_000
    // Hard cap on the total point count sent to the GPU.
    private let maxTotalPoints = 300_000

    // Per-anchor accumulated data (keyed by ARMeshAnchor.identifier)
    private var anchorVertexCounts: [UUID: Int]              = [:]
    private var anchorPositions:    [UUID: [SIMD3<Float>]]   = [:]
    private var anchorColors:       [UUID: [SIMD4<Float>]]   = [:]

    private let cloudNode = SCNNode()

    override init() {
        super.init()
        addChildNode(cloudNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Called from the render loop (rendering thread).
    /// Only re-samples anchors whose vertex count has grown since the last call,
    /// so geometry is rebuilt only when there is actually new data to show.
    func update(anchors: [ARMeshAnchor], frame: ARFrame) {
        guard !anchors.isEmpty else { return }

        var anyChanged = false

        for anchor in anchors {
            let newCount  = anchor.geometry.vertices.count
            let lastCount = anchorVertexCounts[anchor.identifier] ?? 0
            guard newCount > lastCount else { continue }

            anchorVertexCounts[anchor.identifier] = newCount
            anyChanged = true

            let positions = extractPositions(from: anchor)
            let colors    = sampleColors(positions: positions, frame: frame)
            anchorPositions[anchor.identifier] = positions
            anchorColors[anchor.identifier]    = colors
        }

        if anyChanged {
            rebuildGeometry()
        }
    }

    // MARK: - Extraction

    private func extractPositions(from anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let geo       = anchor.geometry
        let vSrc      = geo.vertices
        let bufStride = vSrc.stride
        let offset    = vSrc.offset
        let count     = vSrc.count
        let transform = anchor.transform

        // Sub-sample only if the anchor has more vertices than the per-anchor cap.
        let extractStep = max(1, count / maxPointsPerAnchor)
        var positions   = [SIMD3<Float>]()
        positions.reserveCapacity(min(count, maxPointsPerAnchor))

        var i = 0
        while i < count {
            let base = vSrc.buffer.contents().advanced(by: offset + i * bufStride)
            let x = base.load(as: Float.self)
            let y = base.advanced(by: 4).load(as: Float.self)
            let z = base.advanced(by: 8).load(as: Float.self)
            let w4 = transform * SIMD4<Float>(x, y, z, 1)
            positions.append(SIMD3<Float>(w4.x, w4.y, w4.z))
            i += extractStep
        }
        return positions
    }

    // MARK: - Color sampling

    /// Projects each world-space position through the camera and samples YCbCr → RGB.
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

        let fallback = SIMD4<Float>(0.35, 0.35, 0.35, 1)
        var colors = [SIMD4<Float>]()
        colors.reserveCapacity(positions.count)

        for pos in positions {
            let p4 = worldToCamera * SIMD4<Float>(pos.x, pos.y, pos.z, 1)
            guard p4.z < 0 else { colors.append(fallback); continue }

            let depth = -p4.z
            let px = Int(fx * (p4.x / depth) + cx)
            let py = Int(-fy * (p4.y / depth) + cy)   // negate Y: camera +Y up, image +y down

            guard px >= 0, px < imgW, py >= 0, py < imgH else {
                colors.append(fallback); continue
            }

            let yVal = Float(yBase.advanced(by: py * yRowBytes + px)
                .load(as: UInt8.self)) / 255.0

            let cbCrX = px / 2;  let cbCrY = py / 2
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

    // MARK: - Geometry rebuild

    private func rebuildGeometry() {
        var allPositions = [SIMD3<Float>]()
        var allColors    = [SIMD4<Float>]()
        allPositions.reserveCapacity(min(anchorPositions.count * maxPointsPerAnchor, maxTotalPoints))
        allColors.reserveCapacity(allPositions.capacity)

        for id in anchorPositions.keys {
            guard let pos = anchorPositions[id], let col = anchorColors[id] else { continue }
            allPositions += pos
            allColors    += col
        }

        // Sub-sample if over the total GPU cap
        if allPositions.count > maxTotalPoints {
            let subsampleStep = allPositions.count / maxTotalPoints
            allPositions = Swift.stride(from: 0, to: allPositions.count, by: subsampleStep)
                .map { allPositions[$0] }
            allColors = Swift.stride(from: 0, to: allColors.count, by: subsampleStep)
                .map { allColors[$0] }
        }

        applyGeometry(positions: allPositions, colors: allColors)
    }

    // MARK: - Geometry application

    private func applyGeometry(positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        guard !positions.isEmpty else { return }

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

        cloudNode.geometry = geo
    }
}
