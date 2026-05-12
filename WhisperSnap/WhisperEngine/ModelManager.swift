import Foundation
import SwiftUI
import WhisperKit

struct ModelDownloadProgress: Equatable {
    let fraction: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let speedBytesPerSecond: Double
    let destinationPath: String
}

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeDescription: String

    static func displayName(for id: String) -> String {
        switch id {
        case "openai_whisper-small":
            return "Small"
        case "openai_whisper-large-v3-v20240930_626MB":
            return "Medium Equivalent (626MB)"
        case "openai_whisper-large-v3-v20240930":
            return "Large v3 (Best)"
        default:
            return id.replacingOccurrences(of: "openai_whisper-", with: "").capitalized
        }
    }

    static func from(id: String, sizeDescription: String) -> WhisperModelInfo {
        WhisperModelInfo(
            id: id,
            displayName: Self.displayName(for: id),
            sizeDescription: sizeDescription
        )
    }
}

@Observable
final class ModelManager {
    var listedModels: [WhisperModelInfo] = WhisperModelStorage.preferredLocalModelIDs.map {
        WhisperModelInfo.from(id: $0, sizeDescription: "Loading size…")
    }
    var downloadedModelIDs: Set<String> = []
    var downloadProgress: [String: ModelDownloadProgress] = [:]
    var isDownloading: [String: Bool] = [:]
    var downloadErrors: [String: String] = [:]

    private(set) var remoteModelSizes: [String: Int64] = [:]
    private(set) var onDiskModelSizes: [String: Int64] = [:]

    let downloadBaseURL: URL = WhisperModelStorage.applicationSupportBaseURL()

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        f.includesCount = true
        return f
    }()

    init() {
        migrateLegacyCacheIfNeeded()
        syncWithFilesystem()
        rebuildListedModels(using: WhisperModelStorage.preferredLocalModelIDs)
    }

    // MARK: - Public API

    func fetchAvailableModels() async {
        let idsToUse = WhisperModelStorage.preferredLocalModelIDs

        rebuildListedModels(using: idsToUse)

        for id in idsToUse where remoteModelSizes[id] == nil {
            if let bytes = try? await fetchRemoteModelSize(for: id) {
                remoteModelSizes[id] = bytes
                rebuildListedModels(using: idsToUse)
            }
        }
    }

    func isDownloaded(_ modelID: String) -> Bool {
        downloadedModelIDs.contains(modelID)
    }

    func markAsDownloaded(_ modelID: String) {
        downloadedModelIDs.insert(modelID)
        refreshModelSizeOnDisk(for: modelID)
    }

    func refreshDownloadedModels() {
        syncWithFilesystem()
        rebuildListedModels(using: listedModels.map(\.id))
    }

    func modelInstallPath(for modelID: String) -> String {
        WhisperModelStorage.modelDirectory(for: modelID, downloadBase: downloadBaseURL).path
    }

    func formattedOnDiskSize(for modelID: String) -> String? {
        guard let size = onDiskModelSizes[modelID], size > 0 else { return nil }
        return formatter.string(fromByteCount: size)
    }

    func formattedRemoteSize(for modelID: String) -> String? {
        guard let size = remoteModelSizes[modelID], size > 0 else { return nil }
        return formatter.string(fromByteCount: size)
    }

    func clearError(for modelID: String) {
        downloadErrors.removeValue(forKey: modelID)
    }

    func download(_ modelID: String) async throws {
        isDownloading[modelID] = true
        downloadErrors.removeValue(forKey: modelID)

        let destinationPath = modelInstallPath(for: modelID)
        let totalBytes: Int64 = {
            if let known = remoteModelSizes[modelID], known > 0 { return known }
            return 0
        }()

        var workingTotalBytes = totalBytes
        if workingTotalBytes == 0, let discovered = try? await fetchRemoteModelSize(for: modelID) {
            workingTotalBytes = discovered
            remoteModelSizes[modelID] = discovered
            rebuildListedModels(using: listedModels.map(\.id))
        }

        var lastTimestamp = CFAbsoluteTimeGetCurrent()
        var lastDownloadedBytes: Int64 = 0

        downloadProgress[modelID] = ModelDownloadProgress(
            fraction: 0,
            downloadedBytes: 0,
            totalBytes: workingTotalBytes,
            speedBytesPerSecond: 0,
            destinationPath: destinationPath
        )

        defer {
            isDownloading[modelID] = false
            downloadProgress.removeValue(forKey: modelID)
        }

        do {
            _ = try await WhisperKit.download(
                variant: modelID,
                downloadBase: downloadBaseURL,
                useBackgroundSession: false,
                from: WhisperModelStorage.repoName,
                progressCallback: { [weak self] progress in
                    guard let self else { return }

                    let fraction = min(max(progress.fractionCompleted, 0), 1)
                    let callbackTotalBytes = progress.totalUnitCount > 0 ? Int64(progress.totalUnitCount) : 0
                    let callbackDownloadedBytes = progress.completedUnitCount > 0 ? Int64(progress.completedUnitCount) : 0

                    if callbackTotalBytes > 0, workingTotalBytes == 0 {
                        workingTotalBytes = callbackTotalBytes
                    }

                    let downloadedBytes = callbackDownloadedBytes > 0
                        ? callbackDownloadedBytes
                        : (workingTotalBytes > 0 ? Int64(Double(workingTotalBytes) * fraction) : 0)

                    let now = CFAbsoluteTimeGetCurrent()
                    let dt = max(now - lastTimestamp, 0.001)
                    let deltaBytes = max(downloadedBytes - lastDownloadedBytes, 0)
                    let speed = Double(deltaBytes) / dt

                    lastTimestamp = now
                    lastDownloadedBytes = downloadedBytes

                    DispatchQueue.main.async {
                        if callbackTotalBytes > 0 {
                            self.remoteModelSizes[modelID] = callbackTotalBytes
                        }
                        self.downloadProgress[modelID] = ModelDownloadProgress(
                            fraction: fraction,
                            downloadedBytes: downloadedBytes,
                            totalBytes: workingTotalBytes,
                            speedBytesPerSecond: speed,
                            destinationPath: destinationPath
                        )
                    }
                }
            )

            markAsDownloaded(modelID)
            syncWithFilesystem()
            rebuildListedModels(using: listedModels.map(\.id))
        } catch {
            downloadErrors[modelID] = error.localizedDescription
            throw error
        }
    }

    func delete(_ modelID: String) throws {
        let modelDir = WhisperModelStorage.modelDirectory(for: modelID, downloadBase: downloadBaseURL)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
        downloadedModelIDs.remove(modelID)
        onDiskModelSizes.removeValue(forKey: modelID)
        syncWithFilesystem()
        rebuildListedModels(using: listedModels.map(\.id))
    }

    // MARK: - Private

    private func rebuildListedModels(using ids: [String]) {
        listedModels = ids.map { id in
            let sizeDescription = formattedRemoteSize(for: id) ?? fallbackSizeDescription(for: id)
            return WhisperModelInfo.from(id: id, sizeDescription: sizeDescription)
        }
    }

    private func fallbackSizeDescription(for id: String) -> String {
        if let match = id.range(of: "_([0-9]+)MB$", options: .regularExpression) {
            let value = String(id[match]).replacingOccurrences(of: "_", with: "")
            return value
        }
        switch id {
        case "openai_whisper-small":
            return "~466 MB"
        case "openai_whisper-large-v3-v20240930":
            return "~1.5 GB"
        default:
            return "Unknown size"
        }
    }

    private func syncWithFilesystem() {
        let root = WhisperModelStorage.repoDirectory(downloadBase: downloadBaseURL)
        let fm = FileManager.default

        guard fm.fileExists(atPath: root.path) else {
            downloadedModelIDs = []
            onDiskModelSizes = [:]
            return
        }

        let subdirs = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let modelDirs = subdirs.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        downloadedModelIDs = Set(modelDirs.map { $0.lastPathComponent })

        for modelID in downloadedModelIDs {
            refreshModelSizeOnDisk(for: modelID)
        }
    }

    private func refreshModelSizeOnDisk(for modelID: String) {
        let dir = WhisperModelStorage.modelDirectory(for: modelID, downloadBase: downloadBaseURL)
        onDiskModelSizes[modelID] = directorySize(at: dir)
    }

    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize
            else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private func fetchRemoteModelSize(for modelID: String) async throws -> Int64 {
        var components = URLComponents(string: "https://huggingface.co")!
        components.path = "/api/models/\(WhisperModelStorage.repoName)/tree/main/\(modelID)"
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "1"),
            URLQueryItem(name: "expand", value: "1"),
        ]

        guard let url = components.url else { return 0 }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return 0
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }

        var total: Int64 = 0
        for item in json {
            guard (item["type"] as? String) == "file" else { continue }
            if let size = item["size"] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    private func migrateLegacyCacheIfNeeded() {
        let fm = FileManager.default
        let legacyBase = WhisperModelStorage.legacyDocumentsBaseURL()
        let targetBase = downloadBaseURL

        guard fm.fileExists(atPath: legacyBase.path) else { return }

        do {
            try fm.createDirectory(at: targetBase, withIntermediateDirectories: true)

            // Merge legacy tree into the new Application Support base.
            let legacyEntries = (try? fm.contentsOfDirectory(
                at: legacyBase,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []

            for source in legacyEntries {
                let destination = targetBase.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: destination.path) {
                    // Merge subfolders when needed.
                    if let nested = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                        for nestedSource in nested {
                            let nestedDestination = destination.appendingPathComponent(nestedSource.lastPathComponent, isDirectory: true)
                            if !fm.fileExists(atPath: nestedDestination.path) {
                                try fm.moveItem(at: nestedSource, to: nestedDestination)
                            }
                        }
                    }
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
            }

            // Remove empty legacy base if everything moved.
            let remaining = (try? fm.contentsOfDirectory(atPath: legacyBase.path)) ?? []
            if remaining.isEmpty {
                try? fm.removeItem(at: legacyBase)
            }
        } catch {
            // Non-fatal migration path.
        }
    }
}
