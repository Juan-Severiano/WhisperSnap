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
    nonisolated private static let whisperSpecialTokenRegex = try! NSRegularExpression(pattern: #"<\|[^|>]+\|>"#)
    nonisolated private static let repeatedWhitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    nonisolated private static let spaceBeforePunctuationRegex = try! NSRegularExpression(pattern: #"\s+([,.;:!?])"#)

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
            .map { Self.cleanTranscriptionArtifacts($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return Self.cleanTranscriptionArtifacts(text)
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
        let confirmed = state.confirmedSegments.map { Self.cleanTranscriptionArtifacts($0.text) }
        let unconfirmed = state.unconfirmedSegments.map { Self.cleanTranscriptionArtifacts($0.text) }
        let segments = (confirmed + unconfirmed).filter { !$0.isEmpty }.joined(separator: " ")

        if !segments.isEmpty {
            return segments
        }

        let current = Self.cleanTranscriptionArtifacts(state.currentText)
        if current == "Waiting for speech..." {
            return ""
        }
        return current
    }

    nonisolated static func cleanTranscriptionArtifacts(_ rawText: String) -> String {
        var cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        cleaned = replaceMatches(
            in: cleaned,
            using: whisperSpecialTokenRegex,
            replacement: " "
        )
        cleaned = replaceMatches(
            in: cleaned,
            using: repeatedWhitespaceRegex,
            replacement: " "
        )
        cleaned = replaceMatches(
            in: cleaned,
            using: spaceBeforePunctuationRegex,
            replacement: "$1"
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func replaceMatches(
        in text: String,
        using regex: NSRegularExpression,
        replacement: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
