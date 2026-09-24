import SwiftUI

@main
struct SwingWatchApp: App {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
        }
    }
}
