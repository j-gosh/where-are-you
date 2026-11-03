//
//  FriendsRepository.swift
//  where-are-you
//

import CryptoKit
import Foundation
import WAYCore

/// Friends and the actions on them, for one signed-in account.
@MainActor
protocol FriendsRepository: AnyObject {
    /// The full friend list immediately, then after every change. Finishes with an error if
    /// the source fails.
    func friends() -> AsyncThrowingStream<[Friend], Error>
    func createInvite() async throws -> InviteLink
    func acceptInvite(_ link: InviteLink) async throws
    func removeFriend(_ id: Friend.ID) async throws
    /// The user compared security codes with this friend and they matched.
    func markKeyVerified(_ id: Friend.ID) throws
    /// Accepts a friend's changed key without comparing codes.
    func acceptKeyChange(_ id: Friend.ID) throws
    /// Re-seals the user's profile for every friend, after the user edits it.
    func shareProfile(_ profile: Profile) async
}

/// A fixed, editable friend list. Used by previews, UI tests, and debug builds until
/// location sharing exists.
@MainActor
final class FixtureFriendsRepository: FriendsRepository {
    private let load: () throws -> [Friend]
    private var current: [Friend]?
    private var continuations: [UUID: AsyncThrowingStream<[Friend], Error>.Continuation] = [:]

    init(friends: [Friend]) {
        load = { friends }
    }

    private init(load: @escaping () throws -> [Friend]) {
        self.load = load
    }

    /// Reads `friends.json` from Preview Content, which Xcode leaves out of archived builds.
    static func bundled(now: Date = .now) -> FixtureFriendsRepository {
        FixtureFriendsRepository {
            guard let url = Bundle.main.url(forResource: "friends", withExtension: "json") else {
                throw FriendFixture.Error.missingFile
            }
            return try FriendFixture.decode(Data(contentsOf: url), now: now)
        }
    }

    func friends() -> AsyncThrowingStream<[Friend], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Friend].self)
        do {
            let friends = try current ?? load()
            current = friends
            continuation.yield(friends)
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }

    func createInvite() async throws -> InviteLink {
        try InviteLink(token: InviteLink.generateToken(), inviterKeyId: IdentityKey.generate().publicIdentity.keyId, inviterName: "Test User")
    }

    func acceptInvite(_ link: InviteLink) async throws {
        let friend = Friend(
            id: "invited-\(link.token.prefix(8))",
            displayName: link.inviterName ?? String(localized: "Friend"),
            avatar: Avatar(emoji: nil, color: .orange),
            keyStatus: .trusted(.invite)
        )
        update { $0.append(friend) }
    }

    func removeFriend(_ id: Friend.ID) async throws {
        update { $0.removeAll { $0.id == id } }
    }

    func markKeyVerified(_ id: Friend.ID) throws {
        setKeyStatus(.trusted(.compared), for: id)
    }

    func acceptKeyChange(_ id: Friend.ID) throws {
        setKeyStatus(.trusted(.firstUse), for: id)
    }

    func shareProfile(_ profile: Profile) async {}

    private func setKeyStatus(_ status: FriendRecord.KeyStatus, for id: Friend.ID) {
        update { friends in
            if let index = friends.firstIndex(where: { $0.id == id }) {
                friends[index].keyStatus = status
            }
        }
    }

    private func update(_ change: (inout [Friend]) -> Void) {
        var friends = current ?? []
        change(&friends)
        current = friends
        for continuation in continuations.values {
            continuation.yield(friends)
        }
    }
}

/// The `friends.json` fixture format. Timestamps are relative so the data never goes stale.
enum FriendFixture {
    enum Error: Swift.Error {
        case missingFile
    }

    private struct File: Decodable {
        let friends: [Entry]
    }

    private struct Entry: Decodable {
        struct Location: Decodable {
            let latitude: Double
            let longitude: Double
            let horizontalAccuracy: Double
            let isApproximate: Bool
            let updatedMinutesAgo: Double
        }

        let id: String
        let displayName: String
        let avatar: Avatar
        let location: Location?
        /// "changed" to simulate a friend whose key changed. Otherwise first-use trust.
        let keyStatus: String?
    }

    static func decode(_ data: Data, now: Date) throws -> [Friend] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(File.self, from: data).friends.map { entry in
            Friend(
                id: entry.id,
                displayName: entry.displayName,
                avatar: entry.avatar,
                location: entry.location.map { location in
                    SharedLocation(
                        latitude: location.latitude,
                        longitude: location.longitude,
                        horizontalAccuracy: location.horizontalAccuracy,
                        isApproximate: location.isApproximate,
                        timestamp: now.addingTimeInterval(-location.updatedMinutesAgo * 60)
                    )
                },
                isSharingLocation: entry.location != nil,
                identity: fixtureIdentity(for: entry.id),
                keyStatus: entry.keyStatus == "changed" ? .changed : .trusted(.firstUse)
            )
        }
    }

    /// A stable key per fixture friend, so security codes don't change between launches.
    static func fixtureIdentity(for id: String) -> PublicIdentity? {
        let seed = Data(SHA256.hash(data: Data(id.utf8)))
        return (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)).map { IdentityKey(privateKey: $0).publicIdentity }
    }
}
