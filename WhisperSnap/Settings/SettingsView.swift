import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                GeneralSettingsTab(settings: coordinator.settings)
            }
            Tab("Models", systemImage: "cpu") {
                ModelsSettingsTab(
                    modelManager: coordinator.modelManager,
                    settings: coordinator.settings,
                    coordinator: coordinator
                )
            }
            Tab("AI Cleanup", systemImage: "wand.and.sparkles") {
                AISettingsTab(settings: coordinator.settings)
            }
            Tab("About", systemImage: "info.circle") {
                AboutTab()
            }
        }
        .frame(width: 520, height: 360)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Recording", name: .toggleRecording)
            }

            Section("Behaviour") {
                Toggle("Auto-insert text into focused field", isOn: $settings.autoInsertText)
                Toggle("Always copy to clipboard", isOn: $settings.alwaysCopyToClipboard)
                Toggle("Private mode (don't save history)", isOn: $settings.privateMode)
            }

            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @Bindable var modelManager: ModelManager
    @Bindable var settings: AppSettings
    var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(WhisperModelInfo.known) { model in
                ModelRow(
                    model: model,
                    isActive: settings.activeModel == model.id,
                    isDownloaded: modelManager.isDownloaded(model.id),
                    isDownloading: modelManager.isDownloading[model.id] ?? false,
                    progress: modelManager.downloadProgress[model.id] ?? 0,
                    onSelect: {
                        settings.activeModel = model.id
                        Task { await coordinator.reloadModel() }
                    },
                    onDownload: {
                        Task { try? await modelManager.download(model.id) }
                    },
                    onDelete: {
                        try? modelManager.delete(model.id)
                    }
                )
            }
            .listStyle(.inset)
        }
        .onAppear { modelManager.refreshDownloadedModels() }
    }
}

private struct ModelRow: View {
    let model: WhisperModelInfo
    let isActive: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text("Active")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(.bar)
                            .clipShape(Capsule())
                    }
                }
                Text(model.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else if isDownloaded {
                HStack(spacing: 8) {
                    if !isActive {
                        Button("Use", action: onSelect)
                            .controlSize(.small)
                    }
                    Button("Delete", role: .destructive, action: onDelete)
                        .controlSize(.small)
                }
            } else {
                Button("Download", action: onDownload)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AI Cleanup

private struct AISettingsTab: View {
    @Bindable var settings: AppSettings
    @State private var apiKeyInput: String = ""
    @State private var isSaved = false
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI text cleanup", isOn: $settings.enableSanitization)
                    .help("Uses OpenAI to fix punctuation and remove filler words after transcription.")
            }

            if settings.enableSanitization {
                Section("OpenAI API Key") {
                    HStack {
                        if showKey {
                            TextField("sk-…", text: $apiKeyInput)
                        } else {
                            SecureField("sk-…", text: $apiKeyInput)
                        }
                        Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                            .buttonStyle(.borderless)
                    }

                    HStack {
                        Button("Save Key") {
                            try? settings.saveOpenAIKey(apiKeyInput)
                            isSaved = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                isSaved = false
                            }
                        }
                        .disabled(apiKeyInput.isEmpty)

                        if isSaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }

                        Spacer()

                        Button("Remove Key", role: .destructive) {
                            try? settings.deleteOpenAIKey()
                            apiKeyInput = ""
                        }
                    }

                    Text("Your API key is stored securely in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKeyInput = (try? settings.loadOpenAIKey()) ?? ""
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.bar)

            VStack(spacing: 4) {
                Text("WhisperSnap")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
            }

            Text("Fast, private, local voice transcription powered by WhisperKit.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
