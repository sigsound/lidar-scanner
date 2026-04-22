import SwiftUI
import SceneKit

struct ResultViewerView: View {
    let scan: Scan
    var onRescan: (() -> Void)? = nil

    @EnvironmentObject var scanStore: ScanStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingExportPicker = false
    @State private var exportItem: URL?
    @State private var showingShareSheet = false
    @State private var savedToLibrary = false
    @State private var scnView: SCNView?
    @State private var loadedScene: SCNScene?
    @State private var sceneLoadFailed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let scene = loadedScene {
                // 3D SceneKit viewer — shown once scene is loaded off the main thread.
                SceneViewContainer(scene: scene, scnViewRef: $scnView)
                    .ignoresSafeArea()
                toolbar
            } else if sceneLoadFailed {
                ContentUnavailableView("Could not load mesh", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text("Loading mesh…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Load the USDZ on a background thread so we don't block the main thread
            // and don't OOM by loading while the scan session's Metal buffers are
            // still being released.
            let url = scan.usdzURL
            let scene = await Task.detached(priority: .userInitiated) {
                try? SCNScene(url: url, options: nil)
            }.value
            if let scene {
                loadedScene = scene
            } else {
                sceneLoadFailed = true
            }
        }
        .navigationBarHidden(true)
        .confirmationDialog("Export Format", isPresented: $showingExportPicker, titleVisibility: .visible) {
            Button("Share as USDZ") { prepareExport(format: .usdz) }
            Button("Share as OBJ (ZIP)") { prepareExport(format: .objZip) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingShareSheet) {
            if let item = exportItem {
                ShareSheet(url: item)
            }
        }
        .alert("Saved to Library", isPresented: $savedToLibrary) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your scan has been saved and is available in Past Scans.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton(label: "Export", icon: "square.and.arrow.up") {
                showingExportPicker = true
            }

            Divider().frame(height: 44)

            toolbarButton(label: "Save to Library", icon: "tray.and.arrow.down") {
                saveToLibrary()
            }

            Divider().frame(height: 44)

            toolbarButton(label: "Rescan", icon: "arrow.counterclockwise") {
                if let onRescan {
                    onRescan()
                } else {
                    dismiss()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func toolbarButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.primary)
    }

    private enum ExportFormat { case usdz, objZip }

    private func prepareExport(format: ExportFormat) {
        switch format {
        case .usdz:
            exportItem = scan.usdzURL
        case .objZip:
            exportItem = scan.objZipURL
        }
        showingShareSheet = true
    }

    private func saveToLibrary() {
        scanStore.saveScan(scan)
        savedToLibrary = true
    }
}

// MARK: - SceneKit View Container

private struct SceneViewContainer: UIViewRepresentable {
    let scene: SCNScene
    @Binding var scnViewRef: SCNView?

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        scnView.backgroundColor = UIColor.systemBackground
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.showsStatistics = false
        scnView.antialiasingMode = .multisampling4X

        scnView.scene = scene
        positionCamera(in: scnView, scene: scene)

        DispatchQueue.main.async {
            scnViewRef = scnView
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func positionCamera(in scnView: SCNView, scene: SCNScene) {
        let (min, max) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (min.x + max.x) / 2,
            (min.y + max.y) / 2,
            (min.z + max.z) / 2
        )
        let maxDim = Swift.max(max.x - min.x, max.y - min.y, max.z - min.z)

        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            center.x + Float(maxDim) * 0.6,
            center.y + Float(maxDim) * 0.8,
            center.z + Float(maxDim) * 0.6
        )
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
