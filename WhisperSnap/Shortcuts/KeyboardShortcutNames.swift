import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRealtimeMode = Self(
        "toggleRealtimeMode",
        default: .init(.r, modifiers: [.control, .option])
    )
}
