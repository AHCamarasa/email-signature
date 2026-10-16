import SwiftUI

@main
struct ATrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Connectivity.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await LogUploader.shared.flush() }
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            TasksView()
                .tabItem { Label("Tareas", systemImage: "list.bullet") }
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gear") }
        }
    }
}
