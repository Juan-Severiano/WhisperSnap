import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            recordButton
            Divider().padding(.horizontal, 8)
            lastResultSection
            Divider().padding(.horizontal, 8)
            menuActions
        }
        .frame(width: 280)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var recordButton: some View {
        let state = coordinator.appState.recordingState
        Button(action: coordinator.toggleRecording) {
            HStack(spacing: 8) {
                StatusItemIcon(state: state)
                    .frame(width: 20)
                Text(buttonLabel(for: state))
                    .fontWeight(.medium)
                Spacer()
                if case .recording = state {
                    Text("⌥⌘R")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(recordButtonBackground(for: state))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .disabled(state == .processing)
    }

    @ViewBuilder
    private var lastResultSection: some View {
        if let text = coordinator.appState.recordingState.lastText {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            }
            .padding(.vertical, 4)

            Divider().padding(.horizontal, 8)
        } else if let error = coordinator.appState.recordingState.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 8)
        }
    }

    private var menuActions: some View {
        VStack(spacing: 2) {
            MenuBarButton(label: "Show History", icon: "clock") {
                openWindow(id: "history")
            }

            MenuBarButton(label: "Settings", icon: "gear") {
                openSettings()
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 2)

            MenuBarButton(label: "Quit WhisperSnap", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, 4)
    }

    private func buttonLabel(for state: RecordingState) -> String {
        switch state {
        case .idle: "Start Recording"
        case .recording: "Stop Recording"
        case .processing: "Transcribing…"
        case .done: "Start Recording"
        case .error: "Start Recording"
        }
    }

    private func recordButtonBackground(for state: RecordingState) -> Color {
        switch state {
        case .recording: Color.red.opacity(0.12)
        case .processing: Color.blue.opacity(0.08)
        default: Color.secondary.opacity(0.08)
        }
    }
}

private struct MenuBarButton: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}
