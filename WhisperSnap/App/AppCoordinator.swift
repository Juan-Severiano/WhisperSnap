import AppKit
import AVFoundation
import SwiftData
import SwiftUI

@Observable
final class AppCoordinator {
    var appState = AppState()
    let modelManager = ModelManager()
    let settings = AppSettings()

    private let audioCapture = AudioCaptureManager()
    private let whisperEngine = WhisperEngineManager()
    private let sanitizer = TextSanitizerService()
    private let inserter = AccessibilityInserter()

    private var modelContainer: ModelContainer?

    init() {}

    func setup(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        ShortcutManager.setup(coordinator: self)
        inserter.requestPermissionIfNeeded()
        modelManager.refreshDownloadedModels()
        Task { await preloadModel() }
    }

    // MARK: - Recording Flow

    func toggleRecording() {
        switch appState.recordingState {
        case .idle, .done, .error:
            Task { await startRecording() }
        case .recording:
            Task { await stopAndTranscribe() }
        case .processing:
            break
        }
    }

    private func startRecording() async {
        do {
            try await audioCapture.startRecording()
            appState.recordingState = .recording
        } catch {
            appState.recordingState = .error(error.localizedDescription)
            scheduleReset(after: 4)
        }
    }

    private func stopAndTranscribe() async {
        appState.recordingState = .processing
        let startTime = Date()

        do {
            let audioArray = await audioCapture.stopRecording()

            guard !audioArray.isEmpty else {
                appState.recordingState = .error("No audio captured.")
                scheduleReset(after: 3)
                return
            }

            let isLoaded = await whisperEngine.isLoaded
            if !isLoaded {
                try await whisperEngine.loadModel(settings.activeModel)
            }

            let rawText = try await whisperEngine.transcribe(audioArray: audioArray)
            let duration = Date().timeIntervalSince(startTime)

            let (finalText, originalText) = await applySanitizationIfEnabled(rawText)

            appState.recordingState = .done(text: finalText)
            deliverText(finalText)

            if !settings.privateMode {
                saveRecord(text: finalText, originalText: originalText, duration: duration)
            }

            scheduleReset(after: 1.5)
        } catch {
            appState.recordingState = .error(error.localizedDescription)
            scheduleReset(after: 4)
        }
    }

    private func applySanitizationIfEnabled(_ text: String) async -> (final: String, original: String?) {
        guard settings.enableSanitization,
              let key = try? settings.loadOpenAIKey(),
              !text.isEmpty else {
            return (text, nil)
        }
        guard let sanitized = try? await sanitizer.sanitize(text, apiKey: key) else {
            return (text, nil)
        }
        return (sanitized, text)
    }

    // MARK: - Text Delivery

    private func deliverText(_ text: String) {
        if settings.autoInsertText {
            try? inserter.insert(text)
        }
        if settings.alwaysCopyToClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: - Persistence

    private func saveRecord(text: String, originalText: String?, duration: TimeInterval) {
        guard let container = modelContainer else { return }
        let modelName = settings.activeModel  // capture on @MainActor before hopping off
        Task.detached {
            let context = ModelContext(container)
            let record = TranscriptionRecord(
                text: text,
                originalText: originalText,
                duration: duration,
                modelUsed: modelName
            )
            context.insert(record)
            try? context.save()
        }
    }

    // MARK: - Model Loading

    private func preloadModel() async {
        let isLoaded = await whisperEngine.isLoaded
        guard !isLoaded else { return }
        try? await whisperEngine.loadModel(settings.activeModel)
    }

    func reloadModel() async {
        await whisperEngine.unload()
        try? await whisperEngine.loadModel(settings.activeModel)
    }

    // MARK: - Helpers

    private func scheduleReset(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if case .idle = appState.recordingState { return }
            if case .recording = appState.recordingState { return }
            if case .processing = appState.recordingState { return }
            appState.recordingState = .idle
        }
    }
}
