import Foundation

@MainActor
class ScanStore: ObservableObject {
    @Published var scans: [Scan] = []

    nonisolated static var scansDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans")
    }

    init() {
        createScansDirectoryIfNeeded()
        loadScans()
    }

    private func createScansDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: Self.scansDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadScans() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.scansDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        scans = contents.compactMap { folder -> Scan? in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }

            let metadataURL = folder.appendingPathComponent("metadata.json")
            guard
                let data = try? Data(contentsOf: metadataURL),
                let metadata = try? JSONDecoder().decode(ScanMetadata.self, from: data),
                let id = UUID(uuidString: folder.lastPathComponent)
            else { return nil }

            return Scan(id: id, metadata: metadata)
        }.sorted { $0.metadata.date > $1.metadata.date }
    }

    func saveScan(_ scan: Scan) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(scan.metadata) {
            try? data.write(to: scan.metadataURL)
        }
        loadScans()
    }

    func deleteScan(_ scan: Scan) {
        try? FileManager.default.removeItem(at: scan.folderURL)
        scans.removeAll { $0.id == scan.id }
    }
}
