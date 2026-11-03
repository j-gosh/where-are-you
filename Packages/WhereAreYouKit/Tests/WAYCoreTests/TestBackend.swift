//
//  TestBackend.swift
//  WAYCoreTests
//

import Foundation
@testable import WAYCore

/// An in-memory backend that enforces what the Cloud Functions enforce. `caller` stands in
/// for the signed-in user making each request.
actor TestBackend: AccountBackend, FriendsBackend {
    var caller: String
    private(set) var identities: [String: PublicIdentity] = [:]
    private(set) var profileBoxes: [String: SealedBox] = [:]
    private(set) var invites: [String: InviteDocument] = [:]
    private(set) var friendships: Set<Set<String>> = []
    /// recipient → sender → share.
    private(set) var shares: [String: [String: ShareDocument]] = [:]

    init(caller: String) {
        self.caller = caller
    }

    func setCaller(_ uid: String) {
        caller = uid
    }

    func setIdentity(_ identity: PublicIdentity?, for uid: String) {
        identities[uid] = identity
    }

    func setInvite(_ invite: InviteDocument, token: String) {
        invites[token] = invite
    }

    func addFriendship(_ a: String, _ b: String) {
        friendships.insert([a, b])
    }

    // MARK: AccountBackend

    func publicIdentity(of uid: String) async throws -> PublicIdentity? {
        identities[uid]
    }

    func publishIdentity(_ identity: PublicIdentity, for uid: String) async throws {
        identities[uid] = identity
    }

    func ownProfileBox(for uid: String) async throws -> SealedBox? {
        profileBoxes[uid]
    }

    func saveOwnProfileBox(_ box: SealedBox, for uid: String) async throws {
        profileBoxes[uid] = box
    }

    func deleteAccount() async throws {}

    // MARK: FriendsBackend

    nonisolated func friendUIDs(of uid: String) -> AsyncThrowingStream<Set<String>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let friends = await self.friendships.filter { $0.contains(uid) }.flatMap { $0 }.filter { $0 != uid }
                continuation.yield(Set(friends))
                continuation.finish()
            }
        }
    }

    nonisolated func incomingShares(for uid: String) -> AsyncThrowingStream<[ShareDocument], Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(Array(await self.shares[uid, default: [:]].values))
                continuation.finish()
            }
        }
    }

    func outgoingShare(from uid: String, to friendUid: String) async throws -> ShareDocument? {
        shares[friendUid]?[uid]
    }

    func publishProfile(_ box: SealedBox, from uid: String, to friendUid: String) async throws {
        var share = shares[friendUid]?[uid] ?? ShareDocument(senderUid: uid, profile: box, location: nil, isSharingLocation: false)
        share.profile = box
        shares[friendUid, default: [:]][uid] = share
    }

    func createInvite(token: String, inviterUid: String, inviterKeyId: String, expiresAt: Date) async throws {
        invites[token] = InviteDocument(inviterUid: inviterUid, inviterKeyId: inviterKeyId, expiresAt: expiresAt)
    }

    func invite(token: String) async throws -> InviteDocument? {
        invites[token]
    }

    func acceptInvite(token: String) async throws -> String {
        guard let invite = invites[token], invite.expiresAt > .now else { throw InviteError.expiredOrUsed }
        guard invite.inviterUid != caller else { throw InviteError.ownInvite }
        friendships.insert([caller, invite.inviterUid])
        invites[token] = nil
        return invite.inviterUid
    }

    func removeFriend(_ friendUid: String) async throws {
        friendships.remove([caller, friendUid])
        shares[friendUid]?[caller] = nil
        shares[caller]?[friendUid] = nil
    }
}

/// A fully set-up account, registered with the backend.
func makeAccount(_ uid: String, name: String, backend: TestBackend) async -> Account {
    let account = Account(uid: uid, identity: .generate(), profile: Profile(displayName: name, avatar: Avatar(emoji: nil, color: .blue)))
    await backend.setIdentity(account.identity.publicIdentity, for: uid)
    return account
}
