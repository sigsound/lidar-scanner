import SwiftUI
import ARKit
import RoomPlan

struct ScanSessionView: View {
    @EnvironmentObject var scanStore: ScanStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var sessionManager = ARSessionManager()
    @StateObject private var roomCaptureManager = RoomCaptureManager()
    @State private var showingCancelAlert = false
    @State private var navigateToProcessing = false
    @State private var capturedAnchors: [ARMeshAnchor] = []
    @State private var capturedKeyFrames: [CapturedKeyFrame] = []
    @State private var capturedRoom: CapturedRoom?
    @State private var scanStartTime = Date()
    @State private var showCamera = true
    @State private var isStopping = false

    // Thermal monitoring
    @State private var thermalWarning = false
    private let thermalTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Full-screen AR view with point cloud (shares RoomPlan's ARSession)
            ARSCNViewContainer(
                sessionManager: sessionManager,
                showCamera: $showCamera,
                externalARSession: roomCaptureManager.arSession
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                guidanceBanner
                    .padding(.top, 8)
                Spacer()
                if thermalWarning {
                    thermalWarningBanner
                        .padding(.bottom, 8)
                }
                if let warning = sessionManager.activeWarning {
                    warningBanner(warning.rawValue)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        .animation(.default, value: sessionManager.activeWarning?.rawValue)
                }
                bottomBar
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            scanStartTime = Date()
            roomCaptureManager.start()
        }
        .onChange(of: roomCaptureManager.detectedWalls) { _, walls in
            sessionManager.updateCoverage(walls: walls,
                                          objects: roomCaptureManager.detectedObjects)
        }
        .onChange(of: roomCaptureManager.detectedObjects) { _, objects in
            sessionManager.updateCoverage(walls: roomCaptureManager.detectedWalls,
                                          objects: objects)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(thermalTimer) { _ in
            let state = ProcessInfo.processInfo.thermalState
            thermalWarning = state == .serious || state == .critical
        }
        .alert("Cancel Scan?", isPresented: $showingCancelAlert) {
            Button("Cancel Scan", role: .destructive) { dismiss() }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text("Your scan data will be lost.")
        }
        .navigationDestination(isPresented: $navigateToProcessing) {
            ProcessingView(
                meshAnchors: capturedAnchors,
                keyFrames: capturedKeyFrames,
                capturedRoom: capturedRoom,
                duration: Date().timeIntervalSince(scanStartTime),
                onRescan: {
                    navigateToProcessing = false
                    capturedAnchors   = []
                    capturedKeyFrames = []
                    capturedRoom      = nil
                    scanStartTime     = Date()
                    sessionManager.clearCaptureState()
                    roomCaptureManager.restart()
                }
            )
        }
    }

    // MARK: - Sub-views

    private var topBar: some View {
        HStack {
            Button {
                showingCancelAlert = true
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            Spacer()
            Button {
                withAnimation { showCamera.toggle() }
            } label: {
                Image(systemName: showCamera ? "camera.fill" : "camera.slash.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var guidanceBanner: some View {
        Text(sessionManager.guidance.rawValue)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .animation(.default, value: sessionManager.guidance.rawValue)
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            coverageBar
                .padding(.horizontal)

            Button(action: stopScan) {
                if isStopping {
                    Label("Finalising...", systemImage: "hourglass")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Stop & Process", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)
            .disabled(isStopping)
        }
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var coverageBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Coverage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if roomCaptureManager.detectedWalls > 0 || roomCaptureManager.detectedObjects > 0 {
                    Image(systemName: "square.3.layers.3d")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                    Text("\(roomCaptureManager.detectedWalls)W \(roomCaptureManager.detectedObjects)Obj")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.cyan)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(sessionManager.capturedFrameCount) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(sessionManager.capturedFrameCount > 0 ? .green : .secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(sessionManager.meshCoverage * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.25))
                    Capsule()
                        .fill(.green)
                        .frame(width: geo.size.width * CGFloat(sessionManager.meshCoverage))
                        .animation(.linear(duration: 0.3), value: sessionManager.meshCoverage)
                }
            }
            .frame(height: 7)
        }
    }

    private func warningBanner(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.85), in: Capsule())
    }

    private var thermalWarningBanner: some View {
        warningBanner("Device is getting warm — consider pausing")
    }

    // MARK: - Actions

    private func stopScan() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            // Stop RoomPlan and wait for the finalised CapturedRoom
            let room = await roomCaptureManager.stop()
            capturedAnchors = roomCaptureManager.arSession.currentFrame?.anchors
                .compactMap { $0 as? ARMeshAnchor } ?? []
            capturedKeyFrames = sessionManager.capturedKeyFrames
            capturedRoom      = room
            navigateToProcessing = true
            isStopping = false
        }
    }
}
