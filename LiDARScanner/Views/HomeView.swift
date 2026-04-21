import SwiftUI
import ARKit

struct HomeView: View {
    @EnvironmentObject var scanStore: ScanStore
    @State private var showingScanSession = false
    @State private var showingLibrary = false

    private var lidarAvailable: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // App identity
                VStack(spacing: 12) {
                    Image(systemName: "scanner.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text("LiDAR Scanner")
                        .font(.largeTitle.bold())
                    Text("Capture rooms in 3D")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Primary actions
                VStack(spacing: 14) {
                    if lidarAvailable {
                        Button {
                            showingScanSession = true
                        } label: {
                            Label("Start New Scan", systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        lidarUnavailableView
                    }

                    Button {
                        showingLibrary = true
                    } label: {
                        Label("Past Scans", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
            .navigationDestination(isPresented: $showingScanSession) {
                ScanSessionView()
            }
            .navigationDestination(isPresented: $showingLibrary) {
                ScanLibraryView()
            }
        }
    }

    private var lidarUnavailableView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("LiDAR Not Available")
                    .font(.headline)
            }
            Text("This app requires an iPhone 12 Pro or later with a LiDAR sensor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
