import Foundation
import SwiftUI
import WhisperKit

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeDescription: String

    static let known: [WhisperModelInfo] = [
        WhisperModelInfo(id: "openai_whisper-tiny", displayName: "Tiny (Fastest)", sizeDescription: "~75 MB"),
        WhisperModelInfo(id: "openai_whisper-base", displayName: "Base", sizeDescription: "~145 MB"),
        WhisperModelInfo(id: "openai_whisper-small", displayName: "Small", sizeDescription: "~466 MB"),
        WhisperModelInfo(id: "openai_whisper-large-v3-turbo", displayName: "Large v3 Turbo (Best)", sizeDescription: "~809 MB"),
    ]
}

@Observable
final class ModelManager {
    var downloadedModelIDs: Set<String> = []
    var downloadProgress: [String: Double] = [:]
    var isDownloading: [String: Bool] = [:]

    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    func refreshDownloadedModels() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        downloadedModelIDs = Set(contents)
    }

    func isDownloaded(_ modelID: String) -> Bool {
        downloadedModelIDs.contains(modelID)
    }

    func download(_ modelID: String) async throws {
        isDownloading[modelID] = true
        downloadProgress[modelID] = 0
        defer {
            isDownloading[modelID] = false
            downloadProgress.removeValue(forKey: modelID)
        }
        _ = try await WhisperKit(model: modelID, download: true)
        downloadedModelIDs.insert(modelID)
    }

    func delete(_ modelID: String) throws {
        let modelDir = cacheDirectory.appendingPathComponent(modelID)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
        downloadedModelIDs.remove(modelID)
    }
}
