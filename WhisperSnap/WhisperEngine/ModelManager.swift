import Foundation
import SwiftUI
import WhisperKit

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeDescription: String

    // Preferred display metadata for well-known model IDs.
    static func displayName(for id: String) -> String {
        switch id {
        case "openai_whisper-tiny":              return "Tiny (Fastest)"
        case "openai_whisper-base":              return "Base"
        case "openai_whisper-small":             return "Small"
        case "openai_whisper-medium":            return "Medium"
        case "openai_whisper-large-v3":          return "Large v3"
        default:
            
            return id.replacingOccurrences(of: "openai_whisper-", with: "").capitalized
        }
    }

    static func sizeDescription(for id: String) -> String {
        switch id {
        case "openai_whisper-tiny", "openai_whisper-tiny.en":     return "~75 MB"
        case "openai_whisper-base", "openai_whisper-base.en":     return "~145 MB"
        case "openai_whisper-small", "openai_whisper-small.en":   return "~466 MB"
        case "openai_whisper-medium", "openai_whisper-medium.en": return "~766 MB"
        case "openai_whisper-large-v2":                           return "~1.5 GB"
        case "openai_whisper-large-v3":                           return "~1.5 GB"
        case "openai_whisper-large-v3-turbo":                     return "~809 MB"
        default:                                                   return ""
        }
    }

    // Preferred order for well-known IDs (lower = shown first).
    static func sortOrder(for id: String) -> Int {
        let order = [
            "openai_whisper-tiny",
            "openai_whisper-tiny.en",
            "openai_whisper-base",
            "openai_whisper-base.en",
            "openai_whisper-small",
            "openai_whisper-small.en",
            "openai_whisper-medium",
            "openai_whisper-medium.en",
            "openai_whisper-large-v2",
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-turbo",
        ]
        return order.firstIndex(of: id) ?? 999
    }

    static func from(id: String) -> WhisperModelInfo {
        WhisperModelInfo(
            id: id,
            displayName: Self.displayName(for: id),
            sizeDescription: Self.sizeDescription(for: id)
        )
    }

    // Static fallback list — used until the live fetch resolves.
    static let fallback: [WhisperModelInfo] = [
        "openai_whisper-tiny",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-large-v3",
    ].map { Self.from(id: $0) }
}

@Observable
final class ModelManager {
    var listedModels: [WhisperModelInfo] = WhisperModelInfo.fallback
    var downloadedModelIDs: Set<String> = []
    var downloadProgress: [String: Double] = [:]
    var isDownloading: [String: Bool] = [:]

    private static let persistenceKey = "downloadedModelIDs"

    private var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.persistenceKey) as? [String] {
            downloadedModelIDs = Set(saved)
        }
        syncWithFilesystem()
    }

    // MARK: - Public API

    /// Fetches the real model list from the WhisperKit HuggingFace repo and updates `listedModels`.
    func fetchAvailableModels() async {
        do {
            let ids = try await WhisperKit.fetchAvailableModels()
            let models = ids
                .map { WhisperModelInfo.from(id: $0) }
                .sorted { WhisperModelInfo.sortOrder(for: $0.id) < WhisperModelInfo.sortOrder(for: $1.id) }
            if !models.isEmpty {
                listedModels = models
            }
        } catch {
            // Keep fallback list; network may not be available yet.
        }
    }

    func isDownloaded(_ modelID: String) -> Bool {
        downloadedModelIDs.contains(modelID)
    }

    func markAsDownloaded(_ modelID: String) {
        downloadedModelIDs.insert(modelID)
        persist()
    }

    func refreshDownloadedModels() {
        syncWithFilesystem()
    }

    func download(_ modelID: String) async throws {
        isDownloading[modelID] = true
        downloadProgress[modelID] = 0
        defer {
            isDownloading[modelID] = false
            downloadProgress.removeValue(forKey: modelID)
        }
        _ = try await WhisperKit(model: modelID)
        markAsDownloaded(modelID)
    }

    func delete(_ modelID: String) throws {
        let modelDir = cacheDirectory.appendingPathComponent(modelID)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
        downloadedModelIDs.remove(modelID)
        persist()
    }

    // MARK: - Private

    private func syncWithFilesystem() {
        let fm = FileManager.default
        let onDisk = Set((try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [])
        downloadedModelIDs.formUnion(onDisk)
        // Remove IDs we know about (listed models) but are no longer on disk.
        let knownIDs = Set(listedModels.map(\.id))
        downloadedModelIDs = downloadedModelIDs.filter { id in
            knownIDs.contains(id) ? onDisk.contains(id) : true
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(downloadedModelIDs), forKey: Self.persistenceKey)
    }
}
