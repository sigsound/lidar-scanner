import Foundation

struct ScanMetadata: Codable, Hashable {
    let date: Date
    let duration: TimeInterval
    var usdzFileSize: Int64
    var objZipFileSize: Int64

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: usdzFileSize > 0 ? usdzFileSize : objZipFileSize)
    }
}
