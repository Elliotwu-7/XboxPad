import Foundation
import Security

enum KeychainStore {
    private static let service = "com.elliot.xboxpad.auth"

    #if os(macOS)
    private static let macLock = NSLock()
    private static var macStoreDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("XboxPad/Auth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func macFileURL(for account: String) -> URL {
        let safe = account.replacingOccurrences(of: "/", with: "_")
        return macStoreDir.appendingPathComponent("\(safe).json")
    }
    #endif

    @discardableResult
    static func save<T: Encodable>(_ value: T, account: String, synchronizable: Bool = false) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }

        #if os(macOS)
        // Ad-hoc signed macOS DMG builds trigger repeated macOS Keychain prompts or errSecMissingEntitlement (-34018).
        // Store in user-private 0600 Application Support files so login persists reliably with zero prompts.
        macLock.lock()
        defer { macLock.unlock() }
        let url = macFileURL(for: account)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
        #else
        // Clear any existing local or iCloud-synced copy first so there are no duplicates.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var insertQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }

        // Graceful fallback to local-only Keychain if synchronizable write is ever rejected.
        if synchronizable {
            insertQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            return SecItemAdd(insertQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
        #endif
    }

    static func load<T: Codable>(
        _ type: T.Type,
        account: String,
        preferSynchronizable: Bool = false
    ) -> T? {
        #if os(macOS)
        macLock.lock()
        defer { macLock.unlock() }
        let url = macFileURL(for: account)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
        #else
        if preferSynchronizable {
            if let synced = queryItem(type, account: account, synchronizable: kCFBooleanTrue!) {
                return synced
            }
            if let local = queryItem(type, account: account, synchronizable: kCFBooleanFalse!) {
                // Seamless one-time migration from pre-v1.0.16 local Keychain to iCloud Keychain.
                _ = save(local, account: account, synchronizable: true)
                return local
            }
            return nil
        }

        return queryItem(type, account: account, synchronizable: kSecAttrSynchronizableAny)
        #endif
    }

    static func delete(account: String) {
        #if os(macOS)
        macLock.lock()
        defer { macLock.unlock() }
        try? FileManager.default.removeItem(at: macFileURL(for: account))
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    static func clearAll() {
        #if os(macOS)
        macLock.lock()
        defer { macLock.unlock() }
        if let items = try? FileManager.default.contentsOfDirectory(at: macStoreDir, includingPropertiesForKeys: nil) {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    private static func queryItem<T: Decodable>(
        _ type: T.Type,
        account: String,
        synchronizable: CFTypeRef
    ) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
