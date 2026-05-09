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
        DispatchQueue.main.async {
            coord.setup(modelContainer: container)
        }
    }

    var body: some Scene {
        MenuBarExtra("WhisperSnap", image: "Dock") {
            MenuBarView()
                .environment(coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(coordinator)
                .bringWindowToFrontOnAppear()
        }

        Window("Transcription History", id: "history") {
            HistoryView()
                .modelContainer(sharedContainer)
                .bringWindowToFrontOnAppear()
        }
        .defaultSize(width: 600, height: 480)
    }
}
