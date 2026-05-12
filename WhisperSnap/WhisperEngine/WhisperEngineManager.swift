import Foundation
import WhisperKit

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not loaded. Open Settings to download a model."
        case .emptyResult: "Transcription returned no text."
        }
    }
}

actor WhisperEngineManager {
    private var whisperKit: WhisperKit?
    private(set) var isLoaded = false
    private(set) var loadedModelName: String?
    private var realtimeTranscriber: AudioStreamTranscriber?
    private var realtimeTranscriberTask: Task<Void, Never>?

    func loadModel(_ modelName: String) async throws {
        let downloadBase = WhisperModelStorage.applicationSupportBaseURL()
        let modelFolder = WhisperModelStorage.modelDirectory(for: modelName, downloadBase: downloadBase).path
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            modelRepo: WhisperModelStorage.repoName,
            modelFolder: modelFolder,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        loadedModelName = modelName
        isLoaded = true
    }

    func unload() async {
        await stopLocalRealtimeTranscription()
        whisperKit = nil
        isLoaded = false
        loadedModelName = nil
    }

    // language: nil = auto-detect, "en", "pt", "es" etc. for fixed language
    func transcribe(audioArray: [Float], language: String?) async throws -> String {
        guard let kit = whisperKit else { throw TranscriptionError.modelNotLoaded }

        let options = DecodingOptions(language: language)
        let results = try await kit.transcribe(audioArray: audioArray, decodeOptions: options)
        let text = results
            .compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return text
    }

    func startLocalRealtimeTranscription(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let kit = whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard let tokenizer = kit.tokenizer else { throw WhisperError.tokenizerUnavailable() }

        await stopLocalRealtimeTranscription()

        let options = DecodingOptions(language: language)
        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options
        ) { oldState, newState in
            let previous = Self.mergeRealtimeStateText(oldState)
            let current = Self.mergeRealtimeStateText(newState)
            guard previous != current, !current.isEmpty else { return }
            onPartial(current)
        }

        realtimeTranscriber = transcriber
        realtimeTranscriberTask = Task {
            do {
                try await transcriber.startStreamTranscription()
            } catch is CancellationError {
                return
            } catch {
                onFailure(error.localizedDescription)
            }
        }
    }

    func stopLocalRealtimeTranscription() async {
        await realtimeTranscriber?.stopStreamTranscription()
        realtimeTranscriberTask?.cancel()
        realtimeTranscriberTask = nil
        realtimeTranscriber = nil
    }

    nonisolated private static func mergeRealtimeStateText(_ state: AudioStreamTranscriber.State) -> String {
        let confirmed = state.confirmedSegments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let unconfirmed = state.unconfirmedSegments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let segments = (confirmed + unconfirmed).filter { !$0.isEmpty }.joined(separator: " ")

        if !segments.isEmpty {
            return segments
        }

        let current = state.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == "Waiting for speech..." {
            return ""
        }
        return current
    }
}
