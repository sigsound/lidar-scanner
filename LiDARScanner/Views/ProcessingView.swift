import SwiftUI
import ARKit
import RoomPlan

struct ProcessingView: View {
    let meshAnchors: [ARMeshAnchor]
    let keyFrames: [CapturedKeyFrame]
    var capturedRoom: CapturedRoom? = nil
    let duration: TimeInterval
    var onRescan: (() -> Void)? = nil

    @EnvironmentObject var scanStore: ScanStore
    @StateObject private var processor = MeshProcessor()
    @State private var completedScan: Scan?
    @State private var processingError: String?
    @State private var navigateToResult = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                progressRing

                VStack(spacing: 10) {
                    Text(processor.statusMessage)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .animation(.default, value: processor.statusMessage)

                    Text("This may take 15–60 seconds depending on room size")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if let error = processingError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
        }
        .navigationBarHidden(true)
        .task {
            await runProcessing()
        }
        .navigationDestination(isPresented: $navigateToResult) {
            if let scan = completedScan {
                ResultViewerView(scan: scan, onRescan: onRescan)
            }
        }
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.2), lineWidth: 8)
                .frame(width: 110, height: 110)

            if processor.progress >= 1.0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Circle()
                    .trim(from: 0, to: CGFloat(processor.progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: processor.progress)
            }
        }
        .animation(.spring(), value: processor.progress >= 1.0)
    }

    private func runProcessing() async {
        do {
            let scan = try await processor.process(
                meshAnchors: meshAnchors,
                keyFrames: keyFrames,
                capturedRoom: capturedRoom,
                duration: duration
            )
            completedScan = scan
            navigateToResult = true
        } catch {
            processingError = "Processing failed: \(error.localizedDescription)"
        }
    }
}
