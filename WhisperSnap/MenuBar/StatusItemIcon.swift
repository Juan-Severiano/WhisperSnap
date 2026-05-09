import AppKit
import SwiftUI

struct StatusItemIcon: View {
    let state: RecordingState

    var body: some View {
        switch state {
        case .idle:
            if let menuBarIcon {
                Image(nsImage: menuBarIcon)
            } else {
                Image(systemName: "mic")
            }
        case .recording:
            if let menuBarIcon {
                Image(nsImage: menuBarIcon)
            } else {
                Image(systemName: "mic")
            }
        case .processing:
            Image(systemName: "waveform")
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var menuBarIcon: NSImage? {
        guard let source = NSImage(named: "Dock")?.copy() as? NSImage else {
            return nil
        }

        source.size = NSSize(width: 18, height: 18)
        source.isTemplate = true
        return source
    }
}
