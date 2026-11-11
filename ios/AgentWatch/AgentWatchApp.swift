import SwiftUI

@main struct AgentMonitorWatchApp: App {
    @StateObject private var store = WatchStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRoot(store: store)
                .task(id: phase) {
                    store.setActive(phase == .active)
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await store.refresh()
                        try? await Task.sleep(for: .seconds(10))
                    }
                }
        }
    }
}