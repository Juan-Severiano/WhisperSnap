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
    private let realtimeService = RealtimeTranscriptionService()

    private var modelContainer: ModelContainer?
    private var hasSetup = false

    private var realtimeStartedAt: Date?
    private var realtimeCommittedText = ""
    private var realtimeDraftText = ""
    private var localRealtimeLatestText = ""
    private var isRealtimeFallbackInProgress = false
    private var noticeTask: Task<Void, Never>?
    private var activeRealtimeSession: ActiveRealtimeSession?

    private enum ActiveRealtimeSession {
        case local
        case remote
    }

    init() {
        configureRealtimeCallbacks()
    }

    func setup(modelContainer: ModelContainer) {
        guard !hasSetup else { return }
        hasSetup = true
        self.modelContainer = modelContainer
        ShortcutManager.setup(coordinator: self)
        if AppDistribution.supportsDirectTextInsertion {
            inserter.requestPermissionIfNeeded()
        }
        modelManager.refreshDownloadedModels()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard appState.recordingState == .idle else { return }
            hud.update(recordingState: .idle)
        }
        Task { await preloadModel() }
    }

    // MARK: - Recording Flow

    func toggleRecording() {
        switch appState.recordingState {
        case .idle, .done, .error:
            if settings.realtimeEnabled {
                switch settings.realtimeBackend {
                case .local:
                    Task { await startLocalRealtimeRecording() }
                case .remote:
                    Task { await startRemoteRealtimeRecording() }
                }
            } else {
                Task { await startLocalRecording() }
            }

        case .recording:
            Task { await stopAndTranscribe() }

        case .realtimeConnecting, .realtimeStreaming:
            Task { await stopRealtimeSessionAndFinalize() }

        case .processing:
            break
        }
    }

    func stopIfRecording() {
        switch appState.recordingState {
        case .recording:
            Task { await stopAndTranscribe() }
        case .realtimeConnecting, .realtimeStreaming:
            Task { await stopRealtimeSessionAndFinalize() }
        default:
            break
        }
    }

    func toggleRealtimeMode() {
        settings.realtimeEnabled.toggle()
        showNotice(settings.realtimeEnabled ? "Realtime mode enabled" : "Realtime mode disabled")

        guard !settings.realtimeEnabled else { return }
        switch appState.recordingState {
        case .realtimeConnecting, .realtimeStreaming:
            Task { await stopRealtimeSessionAndFinalize() }
        default:
            break
        }
    }

    private func startLocalRecording(notice: String? = nil) async {
        do {
            try await audioCapture.startRecording()
            if let notice {
                showNotice(notice)
            }
            setState(.recording)
        } catch {
            setState(.error(error.localizedDescription))
            scheduleReset(after: 4)
        }
    }

    private func startLocalRealtimeRecording() async {
        setState(.realtimeConnecting)
        resetRealtimeBuffers()
        activeRealtimeSession = .local

        let isLoaded = await whisperEngine.isLoaded
        let loadedModelName = await whisperEngine.loadedModelName
        if !isLoaded || loadedModelName != settings.activeModel {
            appState.isModelLoading = true
            defer { appState.isModelLoading = false }
            do {
                try await whisperEngine.loadModel(settings.activeModel)
                modelManager.markAsDownloaded(settings.activeModel)
            } catch {
                activeRealtimeSession = nil
                await startLocalRecording(notice: "Local realtime unavailable. Using standard local mode.")
                return
            }
        }

        let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage

        do {
            try await whisperEngine.startLocalRealtimeTranscription(
                language: language,
                onPartial: { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let cleaned = WhisperEngineManager.cleanTranscriptionArtifacts(text)
                        guard !cleaned.isEmpty else { return }
                        self.localRealtimeLatestText = cleaned
                        self.setState(.realtimeStreaming(partialText: cleaned))
                    }
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    Task {
                        await self.fallbackToLocalRecording(
                            warning: message.isEmpty
                                ? "Local realtime failed. Using standard local mode."
                                : "Local realtime failed (\(message)). Using standard local mode."
                        )
                    }
                }
            )
            realtimeStartedAt = Date()
            if case .realtimeStreaming = appState.recordingState {
                // Keep existing partial text.
            } else {
                setState(.realtimeStreaming(partialText: ""))
            }
        } catch {
            activeRealtimeSession = nil
            await startLocalRecording(notice: "Local realtime unavailable. Using standard local mode.")
        }
    }

    private func startRemoteRealtimeRecording() async {
        setState(.realtimeConnecting)
        resetRealtimeBuffers()
        activeRealtimeSession = .remote

        guard let apiKeyValue = try? settings.loadOpenAIKey() else {
            await fallbackToLocalRecording(warning: "Realtime needs an OpenAI key. Using local mode.")
            return
        }
        let apiKey = apiKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            await fallbackToLocalRecording(warning: "Realtime needs an OpenAI key. Using local mode.")
            return
        }

        let modelID = settings.activeOnlineModelID
        guard !modelID.isEmpty else {
            await fallbackToLocalRecording(warning: "Realtime model is empty. Using local mode.")
            return
        }
        guard modelID.lowercased().contains("realtime") else {
            await fallbackToLocalRecording(
                warning: "Selected remote model is not websocket realtime. Use gpt-realtime-whisper or Local realtime."
            )
            return
        }

        let language = settings.selectedLanguage == "auto" ? nil : settings.selectedLanguage

        do {
            let config = RealtimeTranscriptionConfig(
                baseURL: settings.onlineBaseURL,
                apiKey: apiKey,
                modelID: modelID,
                language: language
            )

            try await realtimeService.connect(config: config)

            let service = realtimeService
            try await audioCapture.startRealtimeStreaming { samples in
                let pcm16 = Self.pcm16Data(from: samples)
                Task {
                    try? await service.appendPCM16Bytes(pcm16)
                }
            }

            realtimeStartedAt = Date()
            setState(.realtimeStreaming(partialText: ""))
        } catch {
            await fallbackToLocalRecording(warning: "Realtime unavailable. Using local mode.")
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
            copyToClipboard(finalText)

            if !settings.privateMode {
                saveRecord(text: finalText, originalText: originalText, duration: duration, modelUsed: settings.activeModel)
            }

            scheduleReset(after: 3.0)
        } catch {
            setState(.error(error.localizedDescription))
            scheduleReset(after: 4)
        }
    }

    private func stopRealtimeSessionAndFinalize() async {
        switch activeRealtimeSession {
        case .local:
            await stopLocalRealtimeAndFinalize()
        case .remote:
            await stopRemoteRealtimeAndFinalize()
        case .none:
            setState(.idle)
        }
    }

    private func stopRemoteRealtimeAndFinalize() async {
        setState(.processing)

        await audioCapture.stopRealtimeStreaming()
        try? await realtimeService.commitInputBuffer()
        try? await Task.sleep(for: .milliseconds(300))
        realtimeService.disconnect()

        let rawText = WhisperEngineManager.cleanTranscriptionArtifacts(combinedRealtimeText())
        await finalizeRealtimeText(rawText, modelUsed: settings.activeOnlineModelID)
    }

    private func stopLocalRealtimeAndFinalize() async {
        setState(.processing)
        await whisperEngine.stopLocalRealtimeTranscription()
        let rawText = WhisperEngineManager.cleanTranscriptionArtifacts(localRealtimeLatestText)
        await finalizeRealtimeText(rawText, modelUsed: settings.activeModel)
    }

    private func finalizeRealtimeText(_ rawText: String, modelUsed: String) async {
        let normalizedRawText = WhisperEngineManager.cleanTranscriptionArtifacts(rawText)
        let startTime = realtimeStartedAt
        resetRealtimeBuffers()
        activeRealtimeSession = nil

        guard !normalizedRawText.isEmpty else {
            setState(.idle)
            return
        }

        let (finalText, originalText) = await applySanitizationIfEnabled(normalizedRawText)
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0

        setState(.done(text: finalText))
        deliverText(finalText)
        copyToClipboard(finalText)

        if !settings.privateMode {
            saveRecord(
                text: finalText,
                originalText: originalText,
                duration: duration,
                modelUsed: modelUsed
            )
        }

        scheduleReset(after: 3.0)
    }

    private func fallbackToLocalRecording(warning: String) async {
        guard !isRealtimeFallbackInProgress else { return }
        isRealtimeFallbackInProgress = true
        defer { isRealtimeFallbackInProgress = false }

        await audioCapture.stopRealtimeStreaming()
        await whisperEngine.stopLocalRealtimeTranscription()
        realtimeService.disconnect()
        activeRealtimeSession = nil
        resetRealtimeBuffers()

        await startLocalRecording(notice: warning)
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
        if AppDistribution.supportsDirectTextInsertion && settings.autoInsertText {
            try? inserter.insert(text)
        }
        if settings.alwaysCopyToClipboard {
            copyToClipboard(text)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Persistence

    private func saveRecord(text: String, originalText: String?, duration: TimeInterval, modelUsed: String) {
        guard let container = modelContainer else { return }
        Task.detached {
            let context = ModelContext(container)
            let record = TranscriptionRecord(
                text: text,
                originalText: originalText,
                duration: duration,
                modelUsed: modelUsed
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

    // MARK: - Realtime

    private func configureRealtimeCallbacks() {
        realtimeService.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleRealtimeEvent(event)
            }
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeTranscriptionEvent) {
        switch event {
        case .connected:
            break

        case .delta(let delta):
            guard isRealtimeState else { return }
            realtimeDraftText += delta
            setState(.realtimeStreaming(partialText: combinedRealtimeText()))

        case .completed(let transcript):
            guard isRealtimeState else { return }
            let normalized = WhisperEngineManager.cleanTranscriptionArtifacts(transcript)
            if normalized.isEmpty {
                if !realtimeDraftText.isEmpty {
                    appendRealtimeCommittedSegment(realtimeDraftText)
                }
            } else {
                appendRealtimeCommittedSegment(normalized)
            }
            realtimeDraftText = ""
            setState(.realtimeStreaming(partialText: combinedRealtimeText()))

        case .warning(let message):
            guard !message.isEmpty else { return }
            showNotice(message, duration: 2.5)

        case .failed(let message):
            guard isRealtimeState, activeRealtimeSession == .remote else { return }
            Task {
                let warning = message.isEmpty
                    ? "Realtime failed. Using local mode."
                    : "Realtime failed (\(message)). Using local mode."
                await fallbackToLocalRecording(warning: warning)
            }

        case .disconnected:
            break
        }
    }

    private var isRealtimeState: Bool {
        switch appState.recordingState {
        case .realtimeConnecting, .realtimeStreaming:
            true
        default:
            false
        }
    }

    private func appendRealtimeCommittedSegment(_ segment: String) {
        let trimmed = WhisperEngineManager.cleanTranscriptionArtifacts(segment)
        guard !trimmed.isEmpty else { return }

        if realtimeCommittedText.isEmpty {
            realtimeCommittedText = trimmed
        } else {
            realtimeCommittedText += " " + trimmed
        }
    }

    private func combinedRealtimeText() -> String {
        let combined: String
        if realtimeCommittedText.isEmpty {
            combined = realtimeDraftText
        } else if realtimeDraftText.isEmpty {
            combined = realtimeCommittedText
        } else {
            combined = realtimeCommittedText + " " + realtimeDraftText
        }

        return WhisperEngineManager.cleanTranscriptionArtifacts(combined)
    }

    private func resetRealtimeBuffers() {
        realtimeStartedAt = nil
        realtimeCommittedText = ""
        realtimeDraftText = ""
        localRealtimeLatestText = ""
    }

    nonisolated private static func pcm16Data(from floatSamples: [Float]) -> Data {
        var pcmSamples = [Int16]()
        pcmSamples.reserveCapacity(floatSamples.count)

        for sample in floatSamples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = clamped * Float(Int16.max)
            pcmSamples.append(Int16(scaled))
        }

        return pcmSamples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
    }

    // MARK: - Helpers

    private func showNotice(_ message: String, duration: Double = 3.0) {
        appState.transientNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.appState.transientNotice = nil
        }
    }

    private func scheduleReset(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            switch appState.recordingState {
            case .idle, .recording, .realtimeConnecting, .realtimeStreaming, .processing:
                return
            default:
                setState(.idle)
            }
        }
    }
}
