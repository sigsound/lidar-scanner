import SwiftUI

@main
struct LiDARScannerApp: App {
    @StateObject private var scanStore = ScanStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(scanStore)
        }
    }
}
