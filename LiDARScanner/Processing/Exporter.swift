import Foundation
import SceneKit
import ARKit
import UIKit
import RoomPlan
import ZIPFoundation

/// Writes all output files for a completed scan. Must run on the main actor
/// because thumbnail generation requires UIKit (SCNView.snapshot).
@MainActor
enum Exporter {

    static func export(
        bakedMesh: BakedMesh,
        capturedRoom: CapturedRoom? = nil,
        duration: TimeInterval
    ) throws -> Scan {
        let scanID = UUID()
        let folderURL = ScanStore.scansDirectory.appendingPathComponent(scanID.uuidString)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // 1. Build SCNScene from baked mesh
        let scene = buildScene(from: bakedMesh)

        // 2. Export USDZ
        let usdzURL = folderURL.appendingPathComponent("mesh.usdz")
        try exportUSDZ(scene: scene, to: usdzURL)

        // 3. Export OBJ + MTL + texture PNG, then ZIP
        let objURL = folderURL.appendingPathComponent("mesh.obj")
        let mtlURL = folderURL.appendingPathComponent("mesh.mtl")
        let texURL = folderURL.appendingPathComponent("texture.png")
        let zipURL = folderURL.appendingPathComponent("mesh_obj.zip")
        try exportOBJ(bakedMesh: bakedMesh, to: folderURL)
        try createOBJZip(objURL: objURL, mtlURL: mtlURL, textureURL: texURL, zipURL: zipURL)

        // 4. Thumbnail (UIKit — must stay on main thread)
        let thumbURL = folderURL.appendingPathComponent("thumbnail.jpg")
        try generateThumbnail(scene: scene, to: thumbURL)

        // 5. RoomPlan parametric model (if available)
        if let room = capturedRoom {
            let roomURL = folderURL.appendingPathComponent("room.usdz")
            try? room.export(to: roomURL, exportOptions: .parametric)
        }

        // 6. Metadata
        let usdzSize = fileSize(at: usdzURL)
        let zipSize  = fileSize(at: zipURL)
        let metadata = ScanMetadata(date: Date(), duration: duration,
                                    usdzFileSize: usdzSize, objZipFileSize: zipSize)
        let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
        try encoder.encode(metadata).write(to: folderURL.appendingPathComponent("metadata.json"))

        return Scan(id: scanID, metadata: metadata)
    }

    // MARK: - Scene

    private static func buildScene(from bakedMesh: BakedMesh) -> SCNScene {
        let scene = SCNScene()
        let geometry = buildGeometry(from: bakedMesh)

        let material = SCNMaterial()
        material.diffuse.contents  = bakedMesh.atlasImage
        material.isDoubleSided     = true
        material.lightingModel     = .lambert
        geometry.materials         = [material]

        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return scene
    }

    private static func buildGeometry(from bakedMesh: BakedMesh) -> SCNGeometry {
        let vertData = Data(bytes: bakedMesh.vertices, count: bakedMesh.vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertSource = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: bakedMesh.vertices.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let normData = Data(bytes: bakedMesh.normals, count: bakedMesh.normals.count * MemoryLayout<SIMD3<Float>>.stride)
        let normSource = SCNGeometrySource(
            data: normData, semantic: .normal,
            vectorCount: bakedMesh.normals.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let uvData = Data(bytes: bakedMesh.uvCoords, count: bakedMesh.uvCoords.count * MemoryLayout<SIMD2<Float>>.stride)
        let uvSource = SCNGeometrySource(
            data: uvData, semantic: .texcoord,
            vectorCount: bakedMesh.uvCoords.count,
            usesFloatComponents: true, componentsPerVector: 2,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride
        )

        // Sequential indices: 0,1,2,3,4,5,...
        let indices = (0..<UInt32(bakedMesh.vertices.count)).map { $0 }
        let faceData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: faceData, primitiveType: .triangles,
            primitiveCount: bakedMesh.faceCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        return SCNGeometry(sources: [vertSource, normSource, uvSource], elements: [element])
    }

    // MARK: - USDZ

    private static func exportUSDZ(scene: SCNScene, to url: URL) throws {
        scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MeshError.exportFailed("USDZ file not created.")
        }
    }

    // MARK: - OBJ

    private static func exportOBJ(bakedMesh: BakedMesh, to folderURL: URL) throws {
        // Texture PNG
        if let pngData = bakedMesh.atlasImage.pngData() {
            try pngData.write(to: folderURL.appendingPathComponent("texture.png"))
        }

        // MTL
        let mtl = """
        newmtl material0
        Ka 1.000 1.000 1.000
        Kd 1.000 1.000 1.000
        Ks 0.000 0.000 0.000
        d 1.0
        illum 2
        map_Kd texture.png
        """
        try mtl.write(to: folderURL.appendingPathComponent("mesh.mtl"),
                      atomically: true, encoding: .utf8)

        // OBJ — since vertices are already expanded (3 per face), v/vt/vn all share the same index
        var lines = ["# LiDAR Scanner export", "mtllib mesh.mtl", ""]

        for v in bakedMesh.vertices  { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n in bakedMesh.normals   { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")
        for uv in bakedMesh.uvCoords { lines.append("vt \(uv.x) \(1.0 - uv.y)") }  // OBJ flips V
        lines.append("")
        lines.append("usemtl material0")

        for i in 0..<bakedMesh.faceCount {
            let a = i * 3 + 1; let b = a + 1; let c = a + 2   // 1-indexed
            lines.append("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)")
        }

        try lines.joined(separator: "\n")
            .write(to: folderURL.appendingPathComponent("mesh.obj"),
                   atomically: true, encoding: .utf8)
    }

    // MARK: - ZIP

    private static func createOBJZip(
        objURL: URL, mtlURL: URL, textureURL: URL, zipURL: URL
    ) throws {
        try? FileManager.default.removeItem(at: zipURL)
        guard let archive = Archive(url: zipURL, accessMode: .create) else {
            throw MeshError.exportFailed("Could not create ZIP archive.")
        }
        let folder = objURL.deletingLastPathComponent()
        for url in [objURL, mtlURL, textureURL] where FileManager.default.fileExists(atPath: url.path) {
            try archive.addEntry(with: url.lastPathComponent, relativeTo: folder)
        }
    }

    // MARK: - Thumbnail (main thread only)

    private static func generateThumbnail(scene: SCNScene, to url: URL) throws {
        let size = CGSize(width: 512, height: 512)
        let scnView = SCNView(frame: CGRect(origin: .zero, size: size))
        scnView.scene = scene
        scnView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        scnView.autoenablesDefaultLighting = true
        positionCamera(in: scnView, scene: scene)

        guard let jpeg = scnView.snapshot().jpegData(compressionQuality: 0.85) else {
            throw MeshError.thumbnailFailed
        }
        try jpeg.write(to: url)
    }

    private static func positionCamera(in scnView: SCNView, scene: SCNScene) {
        let (min, max) = scene.rootNode.boundingBox
        let center = SCNVector3((min.x+max.x)/2, (min.y+max.y)/2, (min.z+max.z)/2)
        let maxDim  = Swift.max(max.x-min.x, max.y-min.y, max.z-min.z)
        let cam = SCNCamera(); cam.fieldOfView = 55; cam.zFar = 100
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(center.x + maxDim*0.6, center.y + maxDim*0.8, center.z + maxDim*0.6)
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)
        scnView.pointOfView = camNode
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
