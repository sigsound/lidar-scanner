import Foundation

struct Scan: Identifiable, Codable, Hashable {
    let id: UUID
    var metadata: ScanMetadata

    init(id: UUID = UUID(), metadata: ScanMetadata) {
        self.id = id
        self.metadata = metadata
    }
}

extension Scan {
    var folderURL: URL {
        ScanStore.scansDirectory.appendingPathComponent(id.uuidString)
    }

    var usdzURL: URL {
        folderURL.appendingPathComponent("mesh.usdz")
    }

    var objURL: URL {
        folderURL.appendingPathComponent("mesh.obj")
    }

    var mtlURL: URL {
        folderURL.appendingPathComponent("mesh.mtl")
    }

    var textureURL: URL {
        folderURL.appendingPathComponent("texture.png")
    }

    var thumbnailURL: URL {
        folderURL.appendingPathComponent("thumbnail.jpg")
    }

    var metadataURL: URL {
        folderURL.appendingPathComponent("metadata.json")
    }

    var objZipURL: URL {
        folderURL.appendingPathComponent("mesh_obj.zip")
    }
}
