# LiDAR Scanner

A native iOS app for scanning rooms and objects using the iPhone/iPad LiDAR sensor. Captures a real-time colored point cloud, bakes photographic textures onto the mesh, and exports to USDZ or OBJ.

## Requirements

- iPhone or iPad with LiDAR sensor (iPhone 12 Pro or later, iPad Pro 2020 or later)
- iOS 17.0+
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting Started

```bash
git clone https://github.com/sigsound/lidar-scanner.git
cd lidar-scanner
xcodegen generate
open LiDARScanner.xcodeproj
```

Build and run on a physical device — LiDAR and ARKit are not available in the simulator.

---

## Features

### Real-Time Point Cloud
During scanning, the app renders a live colored point cloud built from `ARMeshAnchor` geometry. Each point is colored by sampling the camera's YCbCr pixel buffer at the projected screen position of that world-space point, giving the cloud photographic color rather than a flat tint. The cloud updates at ~15 fps and caps at 60,000 points to keep rendering smooth.

### Camera Feed Toggle
A button in the top-right corner of the scan view toggles between:
- **Camera on** — AR passthrough with the point cloud overlaid
- **Camera off** — near-black background so the colored point cloud stands alone

### Key-Frame Capture
While scanning, the app captures up to 60 key frames (one per second) using reservoir sampling so coverage is spread evenly across the entire scan duration rather than front-loaded. Each frame stores a `UIImage` (converted immediately from the `CVPixelBuffer` on a background thread) plus camera transform and intrinsics.

### Scan Guidance & Warnings
- Live mesh coverage progress bar
- Guidance prompts ("Slowly move your camera", "Keep going", "Looking good")
- Warnings for excessive motion and low light
- Thermal state monitoring — alerts if the device gets too warm

### Texture Baking
After scanning, the mesh is processed offline using a per-face frame selection strategy:

1. **Mesh aggregation** — all `ARMeshAnchor` geometry is merged into a single world-space mesh with correct normals
2. **Per-face frame selection** — for each triangle, the best key frame is chosen where all three vertices project within the image bounds (with a 4% inset margin). Falls back to the highest-scoring frame if none fully contains the face.
3. **Vertex expansion** — each face gets 3 unique vertices so UV coordinates are per-face, eliminating seam artifacts at tile boundaries
4. **Atlas rendering** — one tile per key frame, laid out in a square grid on a 2048×2048 texture atlas

### Export
- **USDZ** — ready for AirDrop, Quick Look, or AR Quick Look on any Apple device
- **OBJ + MTL + PNG** — mesh, material file, and texture atlas zipped for use in Blender, Cinema 4D, or any 3D tool
- **Save to Library** — stores the scan locally with a generated thumbnail for browsing later

### Scan Library
Past scans are listed with auto-generated thumbnails, file sizes, scan date, and duration. Scans can be re-opened in the 3D viewer or deleted with a swipe.

---

## Architecture

```
LiDARScanner/
├── App/
│   └── LiDARScannerApp.swift       — @main entry, ScanStore environment object
├── ARKit/
│   ├── ARSCNViewContainer.swift    — UIViewRepresentable wrapping ARSCNView; drives point cloud
│   ├── ARSessionManager.swift      — @MainActor ObservableObject; key-frame capture, coverage tracking
│   ├── PointCloudNode.swift        — SCNNode that builds point cloud geometry from ARMeshAnchors
│   └── ARViewContainer.swift       — legacy ARView wrapper (unused, kept for reference)
├── Processing/
│   ├── MeshAggregator.swift        — merges all ARMeshAnchors into a single AggregatedMesh
│   ├── TextureBaker.swift          — per-face texture baking; produces BakedMesh with atlas
│   ├── MeshProcessor.swift         — orchestrates the aggregation → bake → export pipeline
│   └── Exporter.swift              — writes USDZ, OBJ/MTL/ZIP, thumbnail, and metadata JSON
├── Models/
│   ├── Scan.swift                  — Identifiable/Codable/Hashable scan model
│   └── ScanMetadata.swift          — date, duration, file sizes
├── Storage/
│   └── ScanStore.swift             — @MainActor ObservableObject; load/save/delete from disk
└── Views/
    ├── HomeView.swift
    ├── ScanSessionView.swift       — scan UI: point cloud view, guidance, stop button, camera toggle
    ├── ProcessingView.swift        — progress ring during mesh processing
    ├── ResultViewerView.swift      — SCNView 3D viewer with export and save actions
    └── ScanLibraryView.swift       — list of past scans with thumbnails
```

---

## Technical Notes

**ARM64 alignment** — ARKit mesh buffers pack vertices at a 12-byte stride. Reading them as `SIMD3<Float>` (which requires 16-byte alignment) causes a misaligned memory access crash on device. Vertices are read as three individual `Float` loads instead.

**YCbCr color sampling** — The camera image is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`. The Y plane is full resolution; the CbCr plane is half resolution. Colors are converted to RGB using BT.601 coefficients.

**ARKit camera projection** — ARKit camera space has +Y pointing up, but image coordinates have +Y pointing down. The Y component must be negated during projection: `py = -fy * (p4.y / depth) + cy`.

**ARSession delegate retention** — `ARSession.delegate` is a `weak var`. The delegate adapter is held in a strong property on `ARSessionManager` to prevent immediate deallocation.

**CIContext and Metal** — Converting `CVPixelBuffer` to `UIImage` on the main thread with a GPU-backed `CIContext` conflicts with ARKit's Metal pipeline. Conversion runs on a background thread using a software-renderer `CIContext`.

---

## Dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — OBJ export ZIP packaging (via Swift Package Manager)
