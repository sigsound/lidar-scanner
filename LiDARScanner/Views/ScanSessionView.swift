import SwiftUI
import ARKit

struct ScanSessionView: View {
    @EnvironmentObject var scanStore: ScanStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var sessionManager = ARSessionManager()
    @State private var showingCancelAlert = false
    @State private var navigateToProcessing = false
    @State private var capturedAnchors: [ARMeshAnchor] = []
    @State private var capturedKeyFrames: [CapturedKeyFrame] = []
    @State private var scanStartTime = Date()
    @State private var showCamera = true

    // Thermal monitoring
    @State private var thermalWarning = false
    private let thermalTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Full-screen AR view with point cloud
            ARSCNViewContainer(sessionManager: sessionManager, showCamera: $showCamera)
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
                duration: Date().timeIntervalSince(scanStartTime),
                onRescan: {
                    navigateToProcessing = false
                    capturedAnchors = []
                    capturedKeyFrames = []
                    scanStartTime = Date()
                    sessionManager.reset()
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
                Label("Stop & Process", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var coverageBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Mesh Coverage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
        capturedAnchors = sessionManager.session?.currentFrame?.anchors
            .compactMap { $0 as? ARMeshAnchor } ?? []
        capturedKeyFrames = sessionManager.capturedKeyFrames
        navigateToProcessing = true
    }
}
