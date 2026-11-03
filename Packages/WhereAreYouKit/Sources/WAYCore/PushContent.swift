//
//  PushContent.swift
//  WAYCore
//
//  Push notifications carry ciphertext. The notification service extension decrypts them with
//  the device's key and a local directory of friends, so the server never sees what they say.
//

import Foundation
import Synchronization

/// Friends' names and public keys, cached on the device for the notification extension
/// (which has no network access to the backend).
public struct FriendDirectory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var displayName: String
        public var publicKey: Data

        public init(displayName: String, publicKey: Data) {
            self.displayName = displayName
            self.publicKey = publicKey
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }
}

public protocol FriendDirectoryStore: Sendable {
    func directory(for account: String) throws -> FriendDirectory
    func save(_ directory: FriendDirectory, for account: String) throws
    func deleteDirectory(for account: String) throws
}

/// Device-local (not synced): each device rebuilds it from the friend list.
public struct KeychainFriendDirectoryStore: FriendDirectoryStore {
    private let item: KeychainItem

    public init(service: String = "WhereAreYou.FriendDirectory", accessGroup: String? = nil) {
        item = KeychainItem(service: service, accessGroup: accessGroup, synchronizable: false)
    }

    public func directory(for account: String) throws -> FriendDirectory {
        guard let data = try item.read(account: account) else { return FriendDirectory() }
        do {
            return try JSONDecoder().decode(FriendDirectory.self, from: data)
        } catch {
            throw KeyStoreError.invalidData
        }
    }

    public func save(_ directory: FriendDirectory, for account: String) throws {
        try item.write(JSONEncoder().encode(directory), account: account)
    }

    public func deleteDirectory(for account: String) throws {
        try item.delete(account: account)
    }
}

/// For previews and tests.
public final class InMemoryFriendDirectoryStore: FriendDirectoryStore {
    private let storage = Mutex<[String: FriendDirectory]>([:])

    public init() {}

    public func directory(for account: String) throws -> FriendDirectory {
        storage.withLock { $0[account] ?? FriendDirectory() }
    }

    public func save(_ directory: FriendDirectory, for account: String) throws {
        storage.withLock { $0[account] = directory }
    }

    public func deleteDirectory(for account: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: account) }
    }
}

public enum PushContent {
    /// Keys in the push's `userInfo`, set by firebase/functions/src/notifications.ts.
    public static let kindKey = "kind"
    public static let fromKey = "fromUid"
    public static let toKey = "toUid"
    /// A `SealedBox` as JSON (binary fields base64).
    public static let boxKey = "box"

    public enum Kind: String, Sendable {
        /// A friend arrived at or left a place you asked about.
        case alertEvent
        /// A friend set an alert on you.
        case alertRequest
    }

    public struct Text: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    /// The decrypted notification text, or `nil` if anything is missing or doesn't verify (the
    /// push's generic text is then shown).
    public static func text(for userInfo: [AnyHashable: Any], keyStore: KeyStore, directory: FriendDirectoryStore) -> Text? {
        guard let kind = (userInfo[kindKey] as? String).flatMap(Kind.init(rawValue:)),
              let fromUid = userInfo[fromKey] as? String,
              let toUid = userInfo[toKey] as? String,
              let boxJSON = userInfo[boxKey] as? String,
              let box = try? JSONDecoder().decode(SealedBox.self, from: Data(boxJSON.utf8)),
              let recipient = try? keyStore.identityKey(for: toUid),
              let entry = try? directory.directory(for: toUid).entries[fromUid],
              let sender = try? PublicIdentity(rawRepresentation: entry.publicKey) else {
            return nil
        }

        switch kind {
        case .alertEvent:
            guard let event = try? Sealing.open(AlertEvent.self, from: box, sender: sender, senderUid: fromUid, recipient: recipient, recipientUid: toUid) else {
                return nil
            }
            let body = switch event.trigger {
            case .arrive: String(localized: "Arrived at \(event.placeName)")
            case .leave: String(localized: "Left \(event.placeName)")
            }
            return Text(title: entry.displayName, body: body)
        case .alertRequest:
            guard let request = try? Sealing.open(AlertRequest.self, from: box, sender: sender, senderUid: fromUid, recipient: recipient, recipientUid: toUid) else {
                return nil
            }
            let body = switch request.trigger {
            case .arrive: String(localized: "\(entry.displayName) will be notified when you arrive at \(request.placeName). You can remove this in Settings.")
            case .leave: String(localized: "\(entry.displayName) will be notified when you leave \(request.placeName). You can remove this in Settings.")
            }
            return Text(title: String(localized: "New Location Alert"), body: body)
        }
    }
}
