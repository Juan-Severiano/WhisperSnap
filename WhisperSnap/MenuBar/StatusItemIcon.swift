import SwiftUI

struct StatusItemIcon: View {
    let state: RecordingState

    var body: some View {
        switch state {
        case .idle:
            Image("Dock")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.variableColor.iterative.reversing)
                .foregroundStyle(.red)
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
}
