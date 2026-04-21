import SceneKit
import ARKit
import simd

/// A SceneKit node that renders the accumulated point cloud.
/// Vertex positions come from ARMeshAnchor geometry; colors are sampled from
/// the current ARFrame's camera image using the same projection math as the
/// texture baker.
final class PointCloudNode: SCNNode {

    // Maximum total points to display (sub-sample if exceeded)
    private let maxPoints = 60_000
    // Take every Nth vertex per anchor to keep updates fast
    private let anchorSampleStride = 3

    private let cloudNode = SCNNode()

    override init() {
        super.init()
        addChildNode(cloudNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Called from the render loop (rendering thread). Rebuilds the point cloud
    /// from the current set of mesh anchors and colors each point from the frame.
    func update(anchors: [ARMeshAnchor], frame: ARFrame) {
        guard !anchors.isEmpty else { return }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(anchors.count * 300)

        for anchor in anchors {
            let geo       = anchor.geometry
            let transform = anchor.transform
            let vSrc      = geo.vertices
            let stride    = vSrc.stride
            let offset    = vSrc.offset
            let count     = vSrc.count

            var i = 0
            while i < count {
                let base = vSrc.buffer.contents().advanced(by: offset + i * stride)
                let x = base.load(as: Float.self)
                let y = base.advanced(by: 4).load(as: Float.self)
                let z = base.advanced(by: 8).load(as: Float.self)
                let world4 = transform * SIMD4<Float>(x, y, z, 1)
                positions.append(SIMD3<Float>(world4.x, world4.y, world4.z))
                i += anchorSampleStride
            }
        }

        // Sub-sample if over the cap
        if positions.count > maxPoints {
            let step = positions.count / maxPoints
            positions = (0..<maxPoints).map { positions[$0 * step] }
        }

        let colors = sampleColors(positions: positions, frame: frame)
        applyGeometry(positions: positions, colors: colors)
    }

    // MARK: - Color sampling

    /// Projects each world-space point through the camera and samples YCbCr → RGB.
    private func sampleColors(positions: [SIMD3<Float>], frame: ARFrame) -> [SIMD4<Float>] {
        let pixelBuffer = frame.capturedImage
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let imgW = CVPixelBufferGetWidth(pixelBuffer)
        let imgH = CVPixelBufferGetHeight(pixelBuffer)

        guard let yBase     = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbCrBase  = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
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
            let py = Int(-fy * (p4.y / depth) + cy)  // negate Y: camera +Y up, image +y down

            guard px >= 0, px < imgW, py >= 0, py < imgH else {
                colors.append(fallback)
                continue
            }

            // Y (luma)
            let yVal = Float(yBase.advanced(by: py * yRowBytes + px)
                .load(as: UInt8.self)) / 255.0

            // CbCr (chroma, half-resolution)
            let cbCrX = px / 2;  let cbCrY = py / 2
            let cbOff = cbCrY * cbCrRowBytes + cbCrX * 2
            let cb = Float(cbCrBase.advanced(by: cbOff)    .load(as: UInt8.self)) / 255.0 - 0.5
            let cr = Float(cbCrBase.advanced(by: cbOff + 1).load(as: UInt8.self)) / 255.0 - 0.5

            // BT.601 YCbCr → RGB
            let r = min(max(yVal + 1.402  * cr,            0), 1)
            let g = min(max(yVal - 0.3441 * cb - 0.7141 * cr, 0), 1)
            let b = min(max(yVal + 1.772  * cb,            0), 1)

            colors.append(SIMD4<Float>(r, g, b, 1))
        }

        return colors
    }

    // MARK: - Geometry

    private func applyGeometry(positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        guard !positions.isEmpty else { return }

        // --- Vertex positions ---
        let posData = Data(bytes: positions, count: positions.count * MemoryLayout<SIMD3<Float>>.stride)
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        // --- Vertex colors (RGBA float) ---
        let colData = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colSource = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        // --- Point element ---
        let indices  = (0..<Int32(positions.count)).map { $0 }
        let idxData  = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element  = SCNGeometryElement(
            data: idxData, primitiveType: .point,
            primitiveCount: positions.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize                  = 8
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 6

        // --- Material: unlit so vertex colors display directly ---
        let geo = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel   = .constant
        mat.diffuse.contents = UIColor.white   // multiplied by vertex color → vertex color
        mat.isDoubleSided   = true
        geo.materials = [mat]

        cloudNode.geometry = geo
    }
}
