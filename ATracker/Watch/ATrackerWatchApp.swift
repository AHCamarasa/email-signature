import SwiftUI

@main
struct ATrackerWatchApp: App {
    init() {
        Connectivity.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            TaskListView()
        }
    }
}
