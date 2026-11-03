//
//  KeyStore.swift
//  WAYCore
//

import Foundation
import Security
import Synchronization

/// Persists each signed-in account's identity key.
public protocol KeyStore: Sendable {
    func identityKey(for account: String) throws -> IdentityKey?
    func save(_ key: IdentityKey, for account: String) throws
    /// Deleting a key that doesn't exist is not an error.
    func deleteIdentityKey(for account: String) throws
}

extension KeyStore {
    /// The stored key for `account`, or a newly generated and saved one when there is none.
    /// `isNew` tells the caller to publish the new public key.
    public func loadOrCreateIdentityKey(for account: String) throws -> (key: IdentityKey, isNew: Bool) {
        if let existing = try identityKey(for: account) {
            return (existing, false)
        }
        let key = IdentityKey.generate()
        try save(key, for: account)
        return (key, true)
    }
}

public enum KeyStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    /// The Keychain item exists but its contents can't be read.
    case invalidData
}

/// Stores keys as generic passwords, as Apple recommends for CryptoKit Curve25519 keys.
///
/// Items are `AfterFirstUnlock` so background location uploads and the notification extension
/// can decrypt while the phone is locked. With `synchronizable`, iCloud Keychain carries the key
/// to the user's other devices.
public struct KeychainKeyStore: KeyStore {
    private let item: KeychainItem

    /// `accessGroup` is the shared Keychain group that lets the app and its extensions see the
    /// same key. `nil` uses the app's default group.
    public init(service: String = "WhereAreYou.IdentityKey", accessGroup: String? = nil, synchronizable: Bool = true) {
        item = KeychainItem(service: service, accessGroup: accessGroup, synchronizable: synchronizable)
    }

    public func identityKey(for account: String) throws -> IdentityKey? {
        guard let data = try item.read(account: account) else { return nil }
        do {
            return try IdentityKey(rawRepresentation: data)
        } catch {
            throw KeyStoreError.invalidData
        }
    }

    public func save(_ key: IdentityKey, for account: String) throws {
        try item.write(key.privateKey.rawRepresentation, account: account)
    }

    public func deleteIdentityKey(for account: String) throws {
        try item.delete(account: account)
    }
}

/// For previews and tests.
public final class InMemoryKeyStore: KeyStore {
    private let keys = Mutex<[String: Data]>([:])

    public init() {}

    public func identityKey(for account: String) throws -> IdentityKey? {
        guard let data = keys.withLock({ $0[account] }) else { return nil }
        return try IdentityKey(rawRepresentation: data)
    }

    public func save(_ key: IdentityKey, for account: String) throws {
        keys.withLock { $0[account] = key.privateKey.rawRepresentation }
    }

    public func deleteIdentityKey(for account: String) throws {
        _ = keys.withLock { $0.removeValue(forKey: account) }
    }
}

/// One generic-password item per account, under a service name.
struct KeychainItem: Sendable {
    let service: String
    let accessGroup: String?
    let synchronizable: Bool

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeyStoreError.invalidData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    func write(_ data: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = synchronizable

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update in place rather than delete-and-add, so a crash can't leave nothing behind.
            var query = baseQuery(account: account)
            query[kSecAttrSynchronizable as String] = synchronizable
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
