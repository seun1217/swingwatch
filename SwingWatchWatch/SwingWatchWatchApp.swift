import SwiftUI

@main
struct SwingWatchWatchApp: App {

    @StateObject private var connectivity = WatchConnectivityManager()
    @StateObject private var workout = WorkoutManager()

    init() {
        // "자동 워크아웃"의 기본값은 켜짐
        UserDefaults.standard.register(defaults: [SettingsKey.autoWorkout: true])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(connectivity)
                .environmentObject(workout)
        }
    }
}

enum SettingsKey {
    static let autoWorkout = "autoWorkout"
}
