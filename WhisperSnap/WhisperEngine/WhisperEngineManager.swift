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

    func loadModel(_ modelName: String) async throws {
        whisperKit = try await WhisperKit(model: modelName)
        loadedModelName = modelName
        isLoaded = true
    }

    func unload() {
        whisperKit = nil
        isLoaded = false
        loadedModelName = nil
    }

    func transcribe(audioArray: [Float]) async throws -> String {
        guard let kit = whisperKit else { throw TranscriptionError.modelNotLoaded }

        let results = try await kit.transcribe(audioArray: audioArray)
        let text = results
            .compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return text
    }
}
