import Foundation

enum WhisperModelStorage {
    nonisolated static let repoName = "argmaxinc/whisperkit-coreml"
    nonisolated static let preferredLocalModelIDs: [String] = [
        "openai_whisper-small",
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3-v20240930",
    ]

    nonisolated static func applicationSupportBaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("huggingface", isDirectory: true)
    }

    nonisolated static func legacyDocumentsBaseURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    nonisolated static func repoDirectory(downloadBase: URL = applicationSupportBaseURL()) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    nonisolated static func modelDirectory(for modelID: String, downloadBase: URL = applicationSupportBaseURL()) -> URL {
        repoDirectory(downloadBase: downloadBase)
            .appendingPathComponent(modelID, isDirectory: true)
    }
}
