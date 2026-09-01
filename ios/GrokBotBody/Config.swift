import Foundation
import Security

enum CloudConfig {
    static let defaultBaseURL = "https://grokbot-body.rowlinerollin.workers.dev"
    private static let overrideKey = "cloudBaseURL"

    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty { return defaultBaseURL }
        return stored
    }

    static func setBaseURL(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: overrideKey)
    }

    private static let listenModeKey = "listenMode"

    /// hold: press the orb to talk. always: keep the mic open. record: hold to record.
    static var listenMode: String {
        let stored = UserDefaults.standard.string(forKey: listenModeKey) ?? ""
        return stored.isEmpty ? "hold" : stored
    }

    static func setListenMode(_ value: String) {
        UserDefaults.standard.set(value, forKey: listenModeKey)
    }

    private static let faceStyleKey = "faceStyle"

    /// orb: Grok Bot slot-eye morph. dark: black ball with white eyes.
    static var faceStyle: String {
        let stored = UserDefaults.standard.string(forKey: faceStyleKey) ?? ""
        return stored.isEmpty ? "orb" : stored
    }

    static func setFaceStyle(_ value: String) {
        UserDefaults.standard.set(value, forKey: faceStyleKey)
    }

    private static let voiceIdKey = "voiceId"

    static var voiceId: String {
        let stored = UserDefaults.standard.string(forKey: voiceIdKey) ?? ""
        return stored.isEmpty ? "eve" : stored
    }

    static func setVoiceId(_ value: String) {
        UserDefaults.standard.set(value, forKey: voiceIdKey)
    }

    private static let xaiAccount = "xaiAPIKey"
    private static let wakeSecretAccount = "wakeSecret"
    private static let wakeURLKey = "wakeURL"
    private static let keychainService = "com.rollin.GrokBotBody"

    static var xaiAPIKey: String? { keychainGet(xaiAccount) }
    static var hasGrokVoice: Bool { xaiAPIKey != nil }
    static func setXaiAPIKey(_ value: String?) { keychainSet(xaiAccount, value) }

    static var wakeURL: String {
        UserDefaults.standard.string(forKey: wakeURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var wakeSecret: String? { keychainGet(wakeSecretAccount) }
    static var hasWakeHook: Bool { !wakeURL.isEmpty }

    static func setWakeHook(url: String, secret: String?) {
        UserDefaults.standard.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: wakeURLKey)
        keychainSet(wakeSecretAccount, secret)
    }

    private static func keychainGet(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func keychainSet(_ account: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static var bodyId: String {
        let key = "bodyId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static var deviceSecret: String {
        let key = "deviceSecret"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let created = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
