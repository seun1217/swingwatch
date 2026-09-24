import SwiftUI

@main
struct SwingWatchWatchApp: App {

    @StateObject private var connectivity = WatchConnectivityManager()
    @StateObject private var keepAlive = KeepAliveManager()

    init() {
        // "자동 백그라운드 유지"의 기본값은 켜짐
        UserDefaults.standard.register(defaults: [SettingsKey.autoKeepAlive: true])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(connectivity)
                .environmentObject(keepAlive)
        }
    }
}

enum SettingsKey {
    static let autoKeepAlive = "autoKeepAlive"
}
