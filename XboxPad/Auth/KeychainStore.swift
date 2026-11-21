import Foundation
import Security

enum KeychainStore {
    private static let service = "com.elliot.xboxpad.auth"

    @discardableResult
    static func save<T: Encodable>(_ value: T, account: String, synchronizable: Bool = false) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }

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
    }

    static func load<T: Codable>(
        _ type: T.Type,
        account: String,
        preferSynchronizable: Bool = false
    ) -> T? {
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
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
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
