import Foundation
import Security
import ServiceManagement
import SwiftUI

enum OnlineTranscriptionPreset: String, CaseIterable {
    case realtimeWhisper
    case gpt4oTranscribe
    case gpt4oMiniTranscribe
    case custom

    var displayName: String {
        switch self {
        case .realtimeWhisper: "gpt-realtime-whisper"
        case .gpt4oTranscribe: "gpt-4o-transcribe"
        case .gpt4oMiniTranscribe: "gpt-4o-mini-transcribe"
        case .custom: "Custom"
        }
    }

    var modelID: String? {
        switch self {
        case .realtimeWhisper: "gpt-realtime-whisper"
        case .gpt4oTranscribe: "gpt-4o-transcribe"
        case .gpt4oMiniTranscribe: "gpt-4o-mini-transcribe"
        case .custom: nil
        }
    }
}

enum RealtimeBackend: String, CaseIterable {
    case local
    case remote

    var displayName: String {
        switch self {
        case .local: "Local (WhisperKit)"
        case .remote: "Remote (OpenAI Realtime)"
        }
    }
}

@Observable
final class AppSettings {
    private static let keychainService = "com.juansev.WhisperSnap"
    private static let openAIKeyAccount = "openai-api-key"

    var activeModel: String = {
        let stored = UserDefaults.standard.string(forKey: "activeModel") ?? "openai_whisper-small"
        if WhisperModelStorage.preferredLocalModelIDs.contains(stored) {
            return stored
        }
        return "openai_whisper-small"
    }() {
        didSet {
            if !WhisperModelStorage.preferredLocalModelIDs.contains(activeModel) {
                activeModel = "openai_whisper-small"
            }
            UserDefaults.standard.set(activeModel, forKey: "activeModel")
        }
    }

    var enableSanitization: Bool = UserDefaults.standard.bool(forKey: "enableSanitization") {
        didSet { UserDefaults.standard.set(enableSanitization, forKey: "enableSanitization") }
    }

    var privateMode: Bool = UserDefaults.standard.bool(forKey: "privateMode") {
        didSet { UserDefaults.standard.set(privateMode, forKey: "privateMode") }
    }

    var alwaysCopyToClipboard: Bool = {
        let key = "alwaysCopyToClipboard"
        if UserDefaults.standard.object(forKey: key) == nil {
            return AppDistribution.isAppStore
        }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet { UserDefaults.standard.set(alwaysCopyToClipboard, forKey: "alwaysCopyToClipboard") }
    }

    var autoInsertText: Bool = {
        let key = "autoInsertText"
        if !AppDistribution.supportsDirectTextInsertion { return false }
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet {
            if !AppDistribution.supportsDirectTextInsertion && autoInsertText {
                autoInsertText = false
                return
            }
            UserDefaults.standard.set(autoInsertText, forKey: "autoInsertText")
        }
    }

    var selectedLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
    }

    var realtimeEnabled: Bool = UserDefaults.standard.bool(forKey: "realtimeEnabled") {
        didSet { UserDefaults.standard.set(realtimeEnabled, forKey: "realtimeEnabled") }
    }

    var realtimeBackend: RealtimeBackend = {
        let raw = UserDefaults.standard.string(forKey: "realtimeBackend") ?? RealtimeBackend.local.rawValue
        return RealtimeBackend(rawValue: raw) ?? .local
    }() {
        didSet { UserDefaults.standard.set(realtimeBackend.rawValue, forKey: "realtimeBackend") }
    }

    var onlineBaseURL: String = UserDefaults.standard.string(forKey: "onlineBaseURL") ?? "https://api.openai.com" {
        didSet { UserDefaults.standard.set(onlineBaseURL, forKey: "onlineBaseURL") }
    }

    var onlineModelPreset: OnlineTranscriptionPreset = {
        let raw = UserDefaults.standard.string(forKey: "onlineModelPreset") ?? OnlineTranscriptionPreset.realtimeWhisper.rawValue
        return OnlineTranscriptionPreset(rawValue: raw) ?? .realtimeWhisper
    }() {
        didSet { UserDefaults.standard.set(onlineModelPreset.rawValue, forKey: "onlineModelPreset") }
    }

    var onlineCustomModelID: String = UserDefaults.standard.string(forKey: "onlineCustomModelID") ?? "" {
        didSet { UserDefaults.standard.set(onlineCustomModelID, forKey: "onlineCustomModelID") }
    }

    var sanitizationMode: SanitizationMode = {
        let raw = UserDefaults.standard.string(forKey: "sanitizationMode") ?? SanitizationMode.clean.rawValue
        return SanitizationMode(rawValue: raw) ?? .clean
    }() {
        didSet { UserDefaults.standard.set(sanitizationMode.rawValue, forKey: "sanitizationMode") }
    }

    var activeOnlineModelID: String {
        if let presetModel = onlineModelPreset.modelID {
            return presetModel
        }
        return onlineCustomModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    // MARK: - Keychain

    func saveOpenAIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.openAIKeyAccount,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func loadOpenAIKey() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.openAIKeyAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func deleteOpenAIKey() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.openAIKeyAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let s): "Failed to save API key (OSStatus \(s))"
            case .loadFailed(let s): "Failed to load API key (OSStatus \(s))"
            case .deleteFailed(let s): "Failed to delete API key (OSStatus \(s))"
            }
        }
    }
}
