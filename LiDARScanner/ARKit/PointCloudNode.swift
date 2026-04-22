import SceneKit
import ARKit
import simd

/// Dense, continuously-accumulating LiDAR point cloud.
///
/// Each frame, ARFrame.smoothedSceneDepth is unprojected pixel-by-pixel into
/// world-space points and deduplicated via a 3cm voxel hash. Points are
/// accumulated into fixed-size chunks; completed chunks are frozen into
/// permanent SCNNodes (never rebuilt). Only the current live chunk (≤10k pts)
/// is rebuilt, keeping the per-frame geometry cost constant regardless of
/// total cloud size.
final class PointCloudNode: SCNNode {

    // MARK: - Configuration
    private let voxelSize: Float  = 0.025    // 2.5 cm cells — finer detail
    private let maxVoxels         = 5_000_000 // stop accepting new points after this
    private let depthStride       = 4        // sample every 4th depth pixel — denser cloud
    private let chunkCap          = 10_000   // freeze a chunk when it reaches this size
    private let liveRebuildHz     = 0.10     // seconds between live-chunk geometry rebuilds
    private let minDepth: Float   = 0.20     // metres
    private let maxDepth: Float   = 8.00     // extended range for large spaces

    // MARK: - Accumulation
    /// Which voxels are already occupied — O(1) insert/lookup, 8 bytes per entry.
    private var occupied  = Set<Int64>()
    /// Permanently frozen geometry nodes — never touched after creation.
    private var frozenNodes: [SCNNode] = []
    /// Current partial chunk, rebuilt at liveRebuildHz.
    private let liveNode = SCNNode()
    private var livePositions: [SIMD3<Float>] = []
    private var liveColors:    [SIMD4<Float>]  = []
    private var lastLiveTime  = TimeInterval(0)

    // MARK: - Init
    override init() {
        super.init()
        occupied.reserveCapacity(maxVoxels)
        livePositions.reserveCapacity(chunkCap)
        liveColors.reserveCapacity(chunkCap)
        addChildNode(liveNode)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    /// Removes all geometry and clears accumulators to free memory before processing.
    func releaseAll() {
        for node in frozenNodes { node.removeFromParentNode() }
        frozenNodes.removeAll(keepingCapacity: false)
        liveNode.geometry = nil
        livePositions.removeAll(keepingCapacity: false)
        liveColors.removeAll(keepingCapacity: false)
        occupied.removeAll(keepingCapacity: false)
    }

    // MARK: - Public update (render thread, every frame)

    func update(frame: ARFrame, time: TimeInterval) {
        // Ingest depth only while under the cap.
        if occupied.count < maxVoxels {
            let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
            if let dm = depthData?.depthMap {
                ingestDepth(depthMap: dm,
                            confidenceMap: depthData?.confidenceMap,
                            frame: frame)
            }
        }

        // Freeze full chunks immediately (only touches the now-empty live arrays).
        if livePositions.count >= chunkCap {
            freezeChunk()
        }

        // Rebuild live geometry at the requested rate.
        if !livePositions.isEmpty, (time - lastLiveTime) >= liveRebuildHz {
            rebuildLive()
            lastLiveTime = time
        }
    }

    // MARK: - Depth ingestion

    private func ingestDepth(
        depthMap:      CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        frame:         ARFrame
    ) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        var confBase: UnsafeMutableRawPointer?
        var confRow  = 0
        if let cm = confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(cm)
            confRow  = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { confidenceMap.map { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }

        let dW   = CVPixelBufferGetWidth(depthMap)
        let dH   = CVPixelBufferGetHeight(depthMap)
        let dRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let dBase = CVPixelBufferGetBaseAddress(depthMap) else { return }

        // RGB colour planes for photographic colouring.
        let rgb   = frame.capturedImage
        CVPixelBufferLockBaseAddress(rgb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) }
        let rW = CVPixelBufferGetWidth(rgb)
        let rH = CVPixelBufferGetHeight(rgb)
        guard let yBase    = CVPixelBufferGetBaseAddressOfPlane(rgb, 0),
              let cbCrBase = CVPixelBufferGetBaseAddressOfPlane(rgb, 1) else { return }
        let yRowB    = CVPixelBufferGetBytesPerRowOfPlane(rgb, 0)
        let cbCrRowB = CVPixelBufferGetBytesPerRowOfPlane(rgb, 1)

        // Intrinsics: depth-map space (scaled from colour-camera intrinsics).
        let m   = frame.camera.intrinsics
        let sx  = Float(dW) / Float(frame.camera.imageResolution.width)
        let sy  = Float(dH) / Float(frame.camera.imageResolution.height)
        let dfx = m[0][0]*sx;  let dfy = m[1][1]*sy
        let dcx = m[2][0]*sx;  let dcy = m[2][1]*sy
        let cfx = m[0][0];     let cfy = m[1][1]
        let ccx = m[2][0];     let ccy = m[2][1]

        let camTf      = frame.camera.transform
        let worldToCam = camTf.inverse

        outer: for dv in Swift.stride(from: 0, to: dH, by: depthStride) {
            for du in Swift.stride(from: 0, to: dW, by: depthStride) {

                // Skip low-confidence pixels (0=low, 1=medium, 2=high).
                if let cb = confBase,
                   cb.advanced(by: dv*confRow + du).load(as: UInt8.self) < 1 { continue }

                let depth = dBase.advanced(by: dv*dRow + du*4).load(as: Float32.self)
                guard depth >= minDepth, depth <= maxDepth else { continue }

                // Unproject: depth pixel → camera space → world space.
                let xCam =  (Float(du) - dcx) / dfx * depth
                let yCam = -(Float(dv) - dcy) / dfy * depth  // flip image-Y → cam-Y
                let zCam = -depth                              // camera looks down −Z
                let w4   = camTf * SIMD4<Float>(xCam, yCam, zCam, 1)
                let wp   = SIMD3<Float>(w4.x, w4.y, w4.z)

                // Skip already-occupied voxels.
                let key = voxelKey(wp)
                guard occupied.insert(key).inserted else { continue }

                // Sample photographic colour at the corresponding RGB pixel.
                let p4  = worldToCam * SIMD4<Float>(wp.x, wp.y, wp.z, 1)
                guard p4.z < 0 else { continue }
                let rpx = Int(cfx * (p4.x / (-p4.z)) + ccx)
                let rpy = Int(-cfy * (p4.y / (-p4.z)) + ccy)

                var col = SIMD4<Float>(0.28, 0.28, 0.28, 1)
                if rpx >= 0, rpx < rW, rpy >= 0, rpy < rH {
                    let yVal = Float(yBase.advanced(by: rpy*yRowB + rpx)
                        .load(as: UInt8.self)) / 255.0
                    let cx2 = rpx/2, cy2 = rpy/2
                    let cb2Off = cy2*cbCrRowB + cx2*2
                    let cb2 = Float(cbCrBase.advanced(by: cb2Off)  .load(as: UInt8.self)) / 255.0 - 0.5
                    let cr  = Float(cbCrBase.advanced(by: cb2Off+1).load(as: UInt8.self)) / 255.0 - 0.5
                    let r   = min(max(yVal + 1.402*cr,             0), 1)
                    let g   = min(max(yVal - 0.3441*cb2 - 0.7141*cr, 0), 1)
                    let b   = min(max(yVal + 1.772*cb2,            0), 1)
                    col = SIMD4<Float>(r, g, b, 1)
                }

                livePositions.append(wp)
                liveColors.append(col)

                if occupied.count >= maxVoxels { break outer }
            }
        }
    }

    // MARK: - Chunk management

    /// Freezes the live chunk into a permanent SCNNode and resets the live buffer.
    private func freezeChunk() {
        guard !livePositions.isEmpty else { return }
        let node = SCNNode()
        node.geometry = buildGeometry(positions: livePositions, colors: liveColors)
        frozenNodes.append(node)
        addChildNode(node)
        livePositions.removeAll(keepingCapacity: true)
        liveColors.removeAll(keepingCapacity: true)
        liveNode.geometry = nil
    }

    /// Rebuilds the live-chunk geometry with whatever points are currently pending.
    private func rebuildLive() {
        liveNode.geometry = buildGeometry(positions: livePositions, colors: liveColors)
    }

    // MARK: - SCNGeometry builder

    private func buildGeometry(
        positions: [SIMD3<Float>],
        colors:    [SIMD4<Float>]
    ) -> SCNGeometry? {
        guard !positions.isEmpty else { return nil }

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
        return geo
    }

    // MARK: - Voxel key

    /// Packs three 20-bit signed voxel indices into an Int64.
    /// ±524,287 voxels × 3 cm = ±157 m per axis — well beyond indoor range.
    private func voxelKey(_ p: SIMD3<Float>) -> Int64 {
        let ix = Int64(Int32((p.x / voxelSize).rounded(.down)))
        let iy = Int64(Int32((p.y / voxelSize).rounded(.down)))
        let iz = Int64(Int32((p.z / voxelSize).rounded(.down)))
        return (ix & 0xFFFFF) | ((iy & 0xFFFFF) << 20) | ((iz & 0xFFFFF) << 40)
    }
}
