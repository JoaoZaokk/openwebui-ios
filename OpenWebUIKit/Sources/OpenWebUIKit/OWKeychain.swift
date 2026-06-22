import Foundation
import Security

/// Where the session token (and optionally saved credentials for silent
/// re-login) live. A protocol so a host app can inject its own storage; the
/// default is Keychain-backed.
public protocol OWTokenStore: AnyObject {
    func loadToken() -> String?
    func save(token: String?)
}

/// Default Keychain-backed store for the JWT bearer token + "remember me"
/// credentials. Open WebUI hands back a long-lived token on signin; we keep it
/// in the Keychain and replay it as `Authorization: Bearer …`.
public final class OWKeychainStore: OWTokenStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.example.openwebui") { self.service = service }

    // MARK: Token
    public func loadToken() -> String? { Self.get("session.token", service: service) }
    public func save(token: String?) { Self.set(token, key: "session.token", service: service) }

    // MARK: Saved credentials ("manter conectado")
    public func loadEmail() -> String? { Self.get("saved.email", service: service) }
    public func loadPassword() -> String? { Self.get("saved.password", service: service) }
    public func saveCredentials(email: String?, password: String?) {
        Self.set(email, key: "saved.email", service: service)
        Self.set(password, key: "saved.password", service: service)
    }

    public func clear() {
        save(token: nil)
        saveCredentials(email: nil, password: nil)
    }

    // MARK: Keychain primitives
    @discardableResult
    static func set(_ value: String?, key: String, service: String) -> Bool {
        guard let value, let data = value.data(using: .utf8) else {
            return delete(key, service: service)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func get(_ key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
