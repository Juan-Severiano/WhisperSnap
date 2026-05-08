import SwiftUI
import SwiftData

@main
struct WhisperSnapApp: App {
    private let sharedContainer: ModelContainer
    @State private var coordinator: AppCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: TranscriptionRecord.self)
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
        sharedContainer = container
        let coord = AppCoordinator()
        _coordinator = State(wrappedValue: coord)
        coord.setup(modelContainer: container)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(coordinator)
        } label: {
            StatusItemIcon(state: coordinator.appState.recordingState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(coordinator)
        }

        Window("Transcription History", id: "history") {
            HistoryView()
                .modelContainer(sharedContainer)
        }
        .defaultSize(width: 600, height: 480)
    }
}
