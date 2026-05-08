import Foundation
import Security
import ServiceManagement
import SwiftUI

@Observable
final class AppSettings {
    private static let keychainService = "com.juansev.WhisperSnap"
    private static let openAIKeyAccount = "openai-api-key"

    var activeModel: String = UserDefaults.standard.string(forKey: "activeModel") ?? "openai_whisper-tiny" {
        didSet { UserDefaults.standard.set(activeModel, forKey: "activeModel") }
    }

    var enableSanitization: Bool = UserDefaults.standard.bool(forKey: "enableSanitization") {
        didSet { UserDefaults.standard.set(enableSanitization, forKey: "enableSanitization") }
    }

    var privateMode: Bool = UserDefaults.standard.bool(forKey: "privateMode") {
        didSet { UserDefaults.standard.set(privateMode, forKey: "privateMode") }
    }

    var alwaysCopyToClipboard: Bool = UserDefaults.standard.bool(forKey: "alwaysCopyToClipboard") {
        didSet { UserDefaults.standard.set(alwaysCopyToClipboard, forKey: "alwaysCopyToClipboard") }
    }

    var autoInsertText: Bool = {
        let key = "autoInsertText"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }() {
        didSet { UserDefaults.standard.set(autoInsertText, forKey: "autoInsertText") }
    }

    var selectedLanguage: String = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage") }
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
