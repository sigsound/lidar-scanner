import SwiftUI

struct ScanLibraryView: View {
    @EnvironmentObject var scanStore: ScanStore
    @State private var selectedScan: Scan?
    @State private var scanToDelete: Scan?
    @State private var showingDeleteConfirm = false

    var body: some View {
        Group {
            if scanStore.scans.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Past Scans")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { scanStore.loadScans() }
        .navigationDestination(item: $selectedScan) { scan in
            ResultViewerView(scan: scan)
        }
        .alert("Delete Scan?", isPresented: $showingDeleteConfirm, presenting: scanToDelete) { scan in
            Button("Delete", role: .destructive) { scanStore.deleteScan(scan) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This scan will be permanently deleted from your device.")
        }
    }

    private var list: some View {
        List {
            ForEach(scanStore.scans) { scan in
                ScanRowView(scan: scan)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedScan = scan }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            scanToDelete = scan
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No scans yet.")
                .font(.title3.bold())
            Text("Tap 'Start New Scan' to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct ScanRowView: View {
    let scan: Scan

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail
            thumbnailView
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(scan.metadata.formattedDate)
                    .font(.headline)
                HStack(spacing: 8) {
                    Label(scan.metadata.formattedDuration, systemImage: "clock")
                    Label(scan.metadata.formattedFileSize, systemImage: "doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = UIImage(contentsOfFile: scan.thumbnailURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "cube.transparent.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
