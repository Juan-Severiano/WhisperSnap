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
    private let hud = RecordingHUDManager()

    private var modelContainer: ModelContainer?

    init() {}

    func setup(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        ShortcutManager.setup(coordinator: self)
        inserter.requestPermissionIfNeeded()
        modelManager.refreshDownloadedModels()
        hud.update(recordingState: .idle)  // show thin idle bar immediately on launch
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

    func stopIfRecording() {
        guard case .recording = appState.recordingState else { return }
        Task { await stopAndTranscribe() }
    }

    private func startRecording() async {
        do {
            try await audioCapture.startRecording()
            setState(.recording)
        } catch {
            setState(.error(error.localizedDescription))
            scheduleReset(after: 4)
        }
    }

    private func stopAndTranscribe() async {
        setState(.processing)
        let startTime = Date()

        do {
            let audioArray = await audioCapture.stopRecording()

            guard !audioArray.isEmpty else {
                setState(.error("No audio captured."))
                scheduleReset(after: 3)
                return
            }

            let isLoaded = await whisperEngine.isLoaded
            if !isLoaded {
                try await whisperEngine.loadModel(settings.activeModel)
            }

            let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage
            let rawText = try await whisperEngine.transcribe(audioArray: audioArray, language: language)
            let duration = Date().timeIntervalSince(startTime)

            let (finalText, originalText) = await applySanitizationIfEnabled(rawText)

            setState(.done(text: finalText))
            deliverText(finalText)

            // Always copy so the HUD can show "Copied" feedback
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)

            if !settings.privateMode {
                saveRecord(text: finalText, originalText: originalText, duration: duration)
            }

            scheduleReset(after: 3.0)
        } catch {
            setState(.error(error.localizedDescription))
            scheduleReset(after: 4)
        }
    }

    private func applySanitizationIfEnabled(_ text: String) async -> (final: String, original: String?) {
        guard settings.enableSanitization,
              let key = try? settings.loadOpenAIKey(),
              !text.isEmpty else {
            return (text, nil)
        }
        guard let sanitized = try? await sanitizer.sanitize(text, apiKey: key, mode: settings.sanitizationMode) else {
            return (text, nil)
        }
        return (sanitized, text)
    }

    // MARK: - State Management

    private func setState(_ state: RecordingState) {
        appState.recordingState = state
        hud.update(recordingState: state)
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
        let modelName = settings.activeModel
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
        appState.isModelLoading = true
        defer { appState.isModelLoading = false }
        do {
            try await whisperEngine.loadModel(settings.activeModel)
            modelManager.markAsDownloaded(settings.activeModel)
        } catch {}
    }

    func reloadModel() async {
        await whisperEngine.unload()
        appState.isModelLoading = true
        defer { appState.isModelLoading = false }
        do {
            try await whisperEngine.loadModel(settings.activeModel)
            modelManager.markAsDownloaded(settings.activeModel)
        } catch {}
    }

    // MARK: - Helpers

    private func scheduleReset(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            switch appState.recordingState {
            case .idle, .recording, .processing: return
            default: setState(.idle)
            }
        }
    }
}
