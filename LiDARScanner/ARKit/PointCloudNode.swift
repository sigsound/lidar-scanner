import SceneKit
import ARKit
import simd

/// Dense, continuously-accumulating point cloud driven by raw LiDAR depth data.
///
/// Each frame, ARFrame.smoothedSceneDepth (or sceneDepth) is unprojected
/// pixel-by-pixel into world-space 3D points. A voxel hash map eliminates
/// duplicates — each 3cm cell stores the best (most recently captured)
/// photographic color. The result mirrors the style of LiDAR-Visual SLAM
/// systems: organic, continuous surface coverage with no triangulation
/// artifacts, growing denser the longer you dwell on an area.
final class PointCloudNode: SCNNode {

    // MARK: - Configuration
    private let voxelSize: Float  = 0.03     // 3 cm grid → dense but fast
    private let maxVoxels         = 200_000  // GPU cap (~200k is fine on A15+)
    private let depthSampleStride = 4        // sample every 4th depth pixel
    private let rebuildInterval   = 0.12     // max ~8 geometry rebuilds / sec
    private let minDepth: Float   = 0.20     // metres — ignore very close hits
    private let maxDepth: Float   = 4.50     // metres — LiDAR reliable range

    // MARK: - Voxel accumulation
    // Key: three 20-bit voxel indices packed into Int64.
    // Value: (world position, RGBA color)
    private var voxelData: [Int64: (SIMD3<Float>, SIMD4<Float>)] = [:]

    // Flat arrays built incrementally — appended as voxels are created.
    private var stablePositions: [SIMD3<Float>] = []
    private var stableColors:    [SIMD4<Float>]  = []
    // New voxels since the last geometry commit.
    private var pendingPositions: [SIMD3<Float>] = []
    private var pendingColors:    [SIMD4<Float>]  = []

    private var lastRebuildTime = TimeInterval(0)
    private let cloudNode = SCNNode()

    // MARK: - Init

    override init() {
        super.init()
        addChildNode(cloudNode)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public update (render thread, every frame)

    func update(frame: ARFrame, time: TimeInterval) {
        guard voxelData.count < maxVoxels else { return }

        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        guard let depthMap = depthData?.depthMap else { return }

        processDepthMap(depthMap: depthMap,
                        confidenceMap: depthData?.confidenceMap,
                        frame: frame)

        // Commit new points to geometry at the target rebuild rate.
        if !pendingPositions.isEmpty,
           (time - lastRebuildTime) >= rebuildInterval {
            commit(at: time)
        }
    }

    // MARK: - Depth processing

    private func processDepthMap(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        frame: ARFrame
    ) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        var confBase: UnsafeMutableRawPointer?
        var confRowBytes = 0
        if let cm = confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confBase     = CVPixelBufferGetBaseAddress(cm)
            confRowBytes = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { confidenceMap.map { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }

        let dW    = CVPixelBufferGetWidth(depthMap)
        let dH    = CVPixelBufferGetHeight(depthMap)
        let dRow  = CVPixelBufferGetBytesPerRow(depthMap)
        guard let dBase = CVPixelBufferGetBaseAddress(depthMap) else { return }

        // Camera image for photographic colour.
        let rgb = frame.capturedImage
        CVPixelBufferLockBaseAddress(rgb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) }
        let rW = CVPixelBufferGetWidth(rgb)
        let rH = CVPixelBufferGetHeight(rgb)
        guard let yBase    = CVPixelBufferGetBaseAddressOfPlane(rgb, 0),
              let cbCrBase = CVPixelBufferGetBaseAddressOfPlane(rgb, 1) else { return }
        let yRowB    = CVPixelBufferGetBytesPerRowOfPlane(rgb, 0)
        let cbCrRowB = CVPixelBufferGetBytesPerRowOfPlane(rgb, 1)

        // Depth-camera intrinsics (colour intrinsics scaled to depth resolution).
        let m   = frame.camera.intrinsics
        let sx  = Float(dW) / Float(frame.camera.imageResolution.width)
        let sy  = Float(dH) / Float(frame.camera.imageResolution.height)
        let dfx = m[0][0] * sx;  let dfy = m[1][1] * sy
        let dcx = m[2][0] * sx;  let dcy = m[2][1] * sy
        // Colour-camera intrinsics (full resolution).
        let cfx = m[0][0]; let cfy = m[1][1]
        let ccx = m[2][0]; let ccy = m[2][1]

        let camTf      = frame.camera.transform
        let worldToCam = camTf.inverse

        outer: for dv in Swift.stride(from: 0, to: dH, by: depthSampleStride) {
            for du in Swift.stride(from: 0, to: dW, by: depthSampleStride) {

                // Reject low-confidence pixels (ARConfidenceLevel: 0=low 1=med 2=high).
                if let cb = confBase {
                    guard cb.advanced(by: dv * confRowBytes + du)
                              .load(as: UInt8.self) >= 1
                    else { continue }
                }

                // Read depth (Float32, metres, positive = distance from camera).
                let depth = dBase.advanced(by: dv * dRow + du * 4)
                    .load(as: Float32.self)
                guard depth >= minDepth, depth <= maxDepth else { continue }

                // Unproject depth pixel → camera space → world space.
                // ARKit camera: looks down −Z, +Y up, +X right.
                let xCam =  (Float(du) - dcx) / dfx * depth
                let yCam = -(Float(dv) - dcy) / dfy * depth   // flip image-Y → cam-Y
                let zCam = -depth                               // depth is +, camera Z is −
                let w4   = camTf * SIMD4<Float>(xCam, yCam, zCam, 1)
                let wp   = SIMD3<Float>(w4.x, w4.y, w4.z)

                // Skip if this voxel is already filled.
                let key = voxelKey(wp)
                guard voxelData[key] == nil else { continue }

                // Sample photographic colour at the corresponding camera pixel.
                let p4 = worldToCam * SIMD4<Float>(wp.x, wp.y, wp.z, 1)
                guard p4.z < 0 else { continue }
                let rpx = Int(cfx * (p4.x / (-p4.z)) + ccx)
                let rpy = Int(-cfy * (p4.y / (-p4.z)) + ccy)

                var col = SIMD4<Float>(0.28, 0.28, 0.28, 1)
                if rpx >= 0, rpx < rW, rpy >= 0, rpy < rH {
                    let yVal = Float(yBase.advanced(by: rpy * yRowB + rpx)
                        .load(as: UInt8.self)) / 255.0
                    let cbCrX = rpx / 2;  let cbCrY = rpy / 2
                    let cbOff = cbCrY * cbCrRowB + cbCrX * 2
                    let cb  = Float(cbCrBase.advanced(by: cbOff)    .load(as: UInt8.self)) / 255.0 - 0.5
                    let cr  = Float(cbCrBase.advanced(by: cbOff + 1).load(as: UInt8.self)) / 255.0 - 0.5
                    let r   = min(max(yVal + 1.402  * cr,            0), 1)
                    let g   = min(max(yVal - 0.3441 * cb - 0.7141 * cr, 0), 1)
                    let b   = min(max(yVal + 1.772  * cb,            0), 1)
                    col = SIMD4<Float>(r, g, b, 1)
                }

                voxelData[key] = (wp, col)
                pendingPositions.append(wp)
                pendingColors.append(col)

                if voxelData.count >= maxVoxels { break outer }
            }
        }
    }

    // MARK: - Geometry commit

    /// Appends pending voxels to the stable arrays and rebuilds SCNGeometry.
    private func commit(at time: TimeInterval) {
        stablePositions += pendingPositions
        stableColors    += pendingColors
        pendingPositions.removeAll(keepingCapacity: true)
        pendingColors.removeAll(keepingCapacity: true)
        lastRebuildTime = time

        applyGeometry(positions: stablePositions, colors: stableColors)
    }

    // MARK: - SCNGeometry

    private func applyGeometry(positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        guard !positions.isEmpty else { return }

        let posData = Data(bytes: positions,
                          count: positions.count * MemoryLayout<SIMD3<Float>>.stride)
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let colData = Data(bytes: colors,
                          count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colSource = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)

        let indices = (0..<Int32(positions.count)).map { $0 }
        let idxData = Data(bytes: indices, count: indices.count * 4)
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .point,
            primitiveCount: positions.count, bytesPerIndex: 4)
        element.pointSize                    = 6
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 5

        let geo = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel    = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided    = true
        geo.materials = [mat]
        cloudNode.geometry = geo
    }

    // MARK: - Voxel key

    /// Packs three 20-bit signed voxel indices into a single Int64.
    /// Range per axis: ±524,287 voxels × 3 cm = ±157 m — far beyond any room.
    private func voxelKey(_ p: SIMD3<Float>) -> Int64 {
        let ix = Int64(Int32((p.x / voxelSize).rounded(.down)))
        let iy = Int64(Int32((p.y / voxelSize).rounded(.down)))
        let iz = Int64(Int32((p.z / voxelSize).rounded(.down)))
        return (ix & 0xFFFFF) | ((iy & 0xFFFFF) << 20) | ((iz & 0xFFFFF) << 40)
    }
}
