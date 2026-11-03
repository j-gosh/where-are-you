//
//  PinnedKeyStore.swift
//  WAYCore
//

import Foundation
import Synchronization

/// The key this device last accepted for a friend. If the friend's published key changes,
/// the app warns until the user accepts or verifies the new one.
public struct PinnedKey: Codable, Hashable, Sendable {
    public enum Trust: String, Codable, Sendable {
        /// The first key seen for this friend, taken on trust.
        case firstUse
        /// Matched the key ID in an invite that arrived over Messages.
        case invite
        /// The user compared security codes with the friend.
        case compared
    }

    public var keyId: String
    public var trust: Trust

    public init(keyId: String, trust: Trust) {
        self.keyId = keyId
        self.trust = trust
    }
}

public protocol PinnedKeyStore: Sendable {
    /// Friend uid → pinned key, for one signed-in account.
    func pins(for account: String) throws -> [String: PinnedKey]
    /// `nil` removes the pin.
    func setPin(_ pin: PinnedKey?, forFriend friendUid: String, account: String) throws
}

/// Keeps pins in the shared Keychain group, so the app and the Messages extension agree, and
/// iCloud Keychain carries verifications to the user's other devices.
public struct KeychainPinnedKeyStore: PinnedKeyStore {
    private let item: KeychainItem

    public init(service: String = "WhereAreYou.PinnedKeys", accessGroup: String? = nil, synchronizable: Bool = true) {
        item = KeychainItem(service: service, accessGroup: accessGroup, synchronizable: synchronizable)
    }

    public func pins(for account: String) throws -> [String: PinnedKey] {
        guard let data = try item.read(account: account) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PinnedKey].self, from: data)
        } catch {
            throw KeyStoreError.invalidData
        }
    }

    public func setPin(_ pin: PinnedKey?, forFriend friendUid: String, account: String) throws {
        var pins = try pins(for: account)
        pins[friendUid] = pin
        try item.write(JSONEncoder().encode(pins), account: account)
    }
}

/// For previews and tests.
public final class InMemoryPinnedKeyStore: PinnedKeyStore {
    private let storage = Mutex<[String: [String: PinnedKey]]>([:])

    public init() {}

    public func pins(for account: String) throws -> [String: PinnedKey] {
        storage.withLock { $0[account] ?? [:] }
    }

    public func setPin(_ pin: PinnedKey?, forFriend friendUid: String, account: String) throws {
        storage.withLock { $0[account, default: [:]][friendUid] = pin }
    }
}
