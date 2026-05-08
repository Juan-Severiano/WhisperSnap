import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.option, .command]))
}

enum ShortcutManager {
    static func setup(coordinator: AppCoordinator) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak coordinator] in
            coordinator?.toggleRecording()
        }
    }
}
