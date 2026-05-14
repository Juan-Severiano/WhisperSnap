import AppKit
import KeyboardShortcuts
import SwiftUI

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
        .frame(width: 700, height: 500)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings

    struct Language {
        let code: String
        let name: String
    }

    static let languages: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "es", name: "Spanish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "it", name: "Italian"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "pl", name: "Polish"),
        Language(code: "ru", name: "Russian"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "hi", name: "Hindi"),
    ]

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Recording") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Double-tap ⌥ Option — start / stop")
                        Text("Hold ⌥ Option — record while held")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Toggle Realtime") {
                    KeyboardShortcuts.Recorder(for: .toggleRealtimeMode)
                }

                Text("Default realtime shortcut: ⌃⌥R")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Realtime") {
                Toggle("Enable realtime mode", isOn: $settings.realtimeEnabled)
                Picker("Realtime engine", selection: Binding(
                    get: { settings.realtimeBackend },
                    set: { newValue in
                        if newValue == .remote && !settings.thirdPartyAIConsentGranted {
                            settings.realtimeBackend = .local
                        } else {
                            settings.realtimeBackend = newValue
                        }
                    }
                )) {
                    ForEach(RealtimeBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text("Default is Local. Use Remote only when you want OpenAI realtime streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.thirdPartyAIConsentGranted {
                    Text("Remote realtime is locked until you allow Third-Party AI Data Sharing in the AI Cleanup tab.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Transcription") {
                Picker("Language", selection: $settings.selectedLanguage) {
                    Text("Detect automatically").tag("auto")
                    Divider()
                    ForEach(Self.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
            }

            Section("Behaviour") {
                Toggle("Auto-insert text into focused field", isOn: $settings.autoInsertText)
                    .disabled(!AppDistribution.supportsDirectTextInsertion)
                Toggle("Always copy to clipboard", isOn: $settings.alwaysCopyToClipboard)
                Toggle("Private mode (don't save history)", isOn: $settings.privateMode)

                if !AppDistribution.supportsDirectTextInsertion {
                    Text("App Store builds copy the transcript to the clipboard. Direct insertion into other apps requires Accessibility access and is only available in the Direct build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

private enum ModelsSubtab: String, CaseIterable, Identifiable {
    case local = "Local"
    case online = "Online"

    var id: String { rawValue }
}

private struct ModelsSettingsTab: View {
    @Bindable var modelManager: ModelManager
    @Bindable var settings: AppSettings
    var coordinator: AppCoordinator

    @State private var selectedSubtab: ModelsSubtab = .local

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedSubtab) {
                ForEach(ModelsSubtab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedSubtab {
                case .local:
                    LocalModelsTab(modelManager: modelManager, settings: settings, coordinator: coordinator)
                case .online:
                    OnlineModelsTab(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .onAppear {
            modelManager.refreshDownloadedModels()
            Task { await modelManager.fetchAvailableModels() }
        }
    }
}

private struct LocalModelsTab: View {
    @Bindable var modelManager: ModelManager
    @Bindable var settings: AppSettings
    var coordinator: AppCoordinator

    var body: some View {
        List(modelManager.listedModels) { model in
            LocalModelRow(
                model: model,
                isActive: settings.activeModel == model.id,
                isDownloaded: modelManager.isDownloaded(model.id),
                isDownloading: modelManager.isDownloading[model.id] ?? false,
                progress: modelManager.downloadProgress[model.id],
                onDiskSize: modelManager.formattedOnDiskSize(for: model.id),
                installPath: modelManager.modelInstallPath(for: model.id),
                errorMessage: modelManager.downloadErrors[model.id],
                onSelect: {
                    settings.activeModel = model.id
                    Task { await coordinator.reloadModel() }
                },
                onDownload: {
                    modelManager.clearError(for: model.id)
                    Task {
                        do {
                            try await modelManager.download(model.id)
                        } catch {
                            // Error is already stored in modelManager.downloadErrors.
                        }
                    }
                },
                onDelete: {
                    do {
                        try modelManager.delete(model.id)
                    } catch {
                        modelManager.downloadErrors[model.id] = error.localizedDescription
                    }
                }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        }
        .listStyle(.inset)
    }
}

private struct LocalModelRow: View {
    let model: WhisperModelInfo
    let isActive: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: ModelDownloadProgress?
    let onDiskSize: String?
    let installPath: String
    let errorMessage: String?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var progressLine: String {
        guard let progress else { return "" }

        let downloaded = byteFormatter.string(fromByteCount: max(progress.downloadedBytes, 0))
        let total = progress.totalBytes > 0
            ? byteFormatter.string(fromByteCount: progress.totalBytes)
            : "Unknown"
        let speedValue = Int64(max(progress.speedBytesPerSecond, 0).rounded())
        let speed = byteFormatter.string(fromByteCount: speedValue)
        let percent = Int((progress.fraction * 100).rounded())

        return "\(downloaded) / \(total) • \(speed)/s • \(percent)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .fontWeight(isActive ? .semibold : .regular)

                        if isActive {
                            Text("Active")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        if isDownloaded {
                            Text("Downloaded")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text("Model ID: \(model.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Remote size: \(model.sizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let onDiskSize {
                        Text("On disk: \(onDiskSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDownloading {
                    EmptyView()
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

            if isDownloading, let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(progressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(progress.destinationPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else if isDownloaded {
                Text(installPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            if let errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct OnlineModelsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("https://api.openai.com", text: $settings.onlineBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Text("Used only when Realtime engine is set to Remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Preset", selection: $settings.onlineModelPreset) {
                    ForEach(OnlineTranscriptionPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                if settings.onlineModelPreset == .custom {
                    TextField("Custom model ID", text: $settings.onlineCustomModelID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                Text("Active model: \(settings.activeOnlineModelID.isEmpty ? "(empty)" : settings.activeOnlineModelID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("For websocket realtime, prefer `gpt-realtime-whisper`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !settings.thirdPartyAIConsentGranted {
                    Text("Third-Party AI Data Sharing permission is required before remote requests can be sent.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            SharedOpenAIKeySection(settings: settings, title: "OpenAI API Key")
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared Key Section

private struct SharedOpenAIKeySection: View {
    @Bindable var settings: AppSettings
    let title: String

    @State private var apiKeyInput: String = ""
    @State private var isSaved = false
    @State private var showKey = false

    var body: some View {
        Section(title) {
            HStack {
                if showKey {
                    TextField("sk-…", text: $apiKeyInput)
                } else {
                    SecureField("sk-…", text: $apiKeyInput)
                }

                Button(showKey ? "Hide" : "Show") {
                    showKey.toggle()
                }
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

            Text("This key is shared with AI Cleanup and stored in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.demoModeEnabled {
                Text("Demo Mode is enabled, so this key is optional for feature testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            apiKeyInput = (try? settings.loadOpenAIKey()) ?? ""
        }
    }
}

// MARK: - AI Cleanup

private struct AISettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Third-Party AI Data Sharing") {
                Toggle("Allow sending data to third-party AI providers", isOn: $settings.thirdPartyAIConsentGranted)

                Text("Optional AI features only run after this permission is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sent data: microphone audio (remote realtime), transcript text (AI cleanup), selected model, language, and request metadata.")
                    Text("Providers: OpenAI (`api.openai.com`) or a provider endpoint you configure.")
                    Text("Purpose: return remote transcription or cleaned text.")
                    Text("Your OpenAI API key is stored in macOS Keychain and only sent to authenticate your requests.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Enable Demo Mode (no API key required)", isOn: $settings.demoModeEnabled)
                Text("Demo Mode simulates remote AI behavior locally so App Review can verify all features without a live key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable AI text cleanup", isOn: Binding(
                    get: { settings.enableSanitization },
                    set: { newValue in
                        if newValue && !settings.thirdPartyAIConsentGranted {
                            settings.enableSanitization = false
                        } else {
                            settings.enableSanitization = newValue
                        }
                    }
                ))
                    .help("Uses OpenAI to fix punctuation and remove filler words after transcription.")

                if !settings.thirdPartyAIConsentGranted {
                    Text("Enable Third-Party AI Data Sharing above to use AI cleanup.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if settings.enableSanitization {
                Section("Mode") {
                    Picker("Cleanup Mode", selection: $settings.sanitizationMode) {
                        ForEach(SanitizationMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                SharedOpenAIKeySection(settings: settings, title: "OpenAI API Key")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var appIcon: NSImage {
        NSApplication.shared.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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

            Text("Third-party AI sharing controls are available in Settings > AI Cleanup.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environment(makeCoordinator())
            .frame(width: 700, height: 500)
            .previewDisplayName("Settings")
    }

    private static func makeCoordinator() -> AppCoordinator {
        let coordinator = AppCoordinator()
        coordinator.appState.recordingState = .idle
        return coordinator
    }
}
#endif
