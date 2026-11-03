//
//  LiveFriendsRepository.swift
//  where-are-you
//

import Foundation
import OSLog
import WAYCore

/// Friends from the backend: listens to friendships and incoming shares, loads each friend's
/// public key, pins it, and keeps the profile this user shares with each friend sealed to
/// current keys.
@MainActor
final class LiveFriendsRepository: FriendsRepository {
    private var account: Account
    private let backend: FriendsBackend
    private let accounts: AccountBackend
    private let pins: PinnedKeyStore
    private let directory: FriendDirectoryStore
    private var savedDirectory: FriendDirectory?

    private var friendUIDs: Set<String> = []
    private var shares: [String: ShareDocument] = [:]
    private var identities: [String: PublicIdentity] = [:]
    private var pinned: [String: PinnedKey] = [:]
    /// Friend uid → the key ID their identity was last requested for ("" for "whatever's
    /// current"), so each change is fetched once.
    private var identityRequests: [String: String] = [:]
    private var hasFriendList = false
    private var hasShares = false
    private var continuation: AsyncThrowingStream<[Friend], Error>.Continuation?

    init(account: Account, backend: FriendsBackend, accounts: AccountBackend, pins: PinnedKeyStore, directory: FriendDirectoryStore) {
        self.account = account
        self.backend = backend
        self.accounts = accounts
        self.pins = pins
        self.directory = directory
    }

    private var inviteFlow: InviteFlow {
        InviteFlow(friends: backend, accounts: accounts, pins: pins)
    }

    // MARK: Listening

    func friends() -> AsyncThrowingStream<[Friend], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Friend].self)
        self.continuation = continuation
        hasFriendList = false
        hasShares = false
        reloadPins()

        let uid = account.uid
        let friendsTask = Task { [weak self, backend] in
            do {
                for try await uids in backend.friendUIDs(of: uid) {
                    self?.apply(friendUIDs: uids)
                }
            } catch {
                self?.fail(error)
            }
        }
        let sharesTask = Task { [weak self, backend] in
            do {
                for try await shares in backend.incomingShares(for: uid) {
                    self?.apply(shares: shares)
                }
            } catch {
                self?.fail(error)
            }
        }
        continuation.onTermination = { _ in
            friendsTask.cancel()
            sharesTask.cancel()
        }
        return stream
    }

    private func apply(friendUIDs uids: Set<String>) {
        friendUIDs = uids
        hasFriendList = true
        reloadPins()
        emit()
        refreshIdentities()
    }

    private func apply(shares newShares: [ShareDocument]) {
        shares = Dictionary(newShares.map { ($0.senderUid, $0) }, uniquingKeysWith: { _, latest in latest })
        hasShares = true
        emit()
        refreshIdentities()
    }

    private func fail(_ error: Error) {
        Logger.friends.error("Friends listener failed: \(error.localizedDescription, privacy: .public)")
        continuation?.finish(throwing: error)
    }

    /// Waits for both listeners' first results, so friends don't flash "waiting" on launch.
    private func emit() {
        guard hasFriendList, hasShares else { return }
        let records = FriendAssembler.assemble(friendUIDs: friendUIDs, shares: shares, identities: identities, pins: pinned, account: account)
        continuation?.yield(records.map(Friend.init))
        saveDirectory(for: records)
    }

    /// Names and keys for the notification extension, which decrypts pushes without network access.
    private func saveDirectory(for records: [FriendRecord]) {
        var entries: [String: FriendDirectory.Entry] = [:]
        for record in records {
            guard let identity = record.identity, let profile = record.profile else { continue }
            entries[record.uid] = FriendDirectory.Entry(displayName: profile.displayName, publicKey: identity.rawRepresentation)
        }
        let updated = FriendDirectory(entries: entries)
        guard updated != savedDirectory else { return }
        do {
            try directory.save(updated, for: account.uid)
            savedDirectory = updated
        } catch {
            Logger.friends.error("Saving the friend directory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Keys

    /// Loads keys for new friends, and reloads a friend's key when what they share says it changed.
    private func refreshIdentities() {
        for uid in friendUIDs {
            let sharedKeyId = shares[uid]?.profile.senderKeyId
            if let known = identities[uid] {
                if let sharedKeyId, sharedKeyId != known.keyId, identityRequests[uid] != sharedKeyId {
                    fetchIdentity(of: uid, requestedFor: sharedKeyId)
                }
            } else if identityRequests[uid] == nil {
                fetchIdentity(of: uid, requestedFor: sharedKeyId ?? "")
            }
        }
    }

    private func fetchIdentity(of uid: String, requestedFor keyId: String) {
        identityRequests[uid] = keyId
        Task { [weak self, accounts] in
            do {
                // nil: they haven't published a key (yet). Their share will prompt another try.
                guard let identity = try await accounts.publicIdentity(of: uid) else { return }
                await self?.didLoad(identity, for: uid)
            } catch {
                Logger.friends.error("Loading a friend's key failed: \(error.localizedDescription, privacy: .public)")
                self?.identityRequests[uid] = nil
            }
        }
    }

    private func didLoad(_ identity: PublicIdentity, for uid: String) async {
        identities[uid] = identity
        if pinned[uid] == nil {
            pin(PinnedKey(keyId: identity.keyId, trust: .firstUse), for: uid)
        }
        emit()
        await syncProfile(to: uid, identity: identity)
    }

    private func reloadPins() {
        do {
            pinned = try pins.pins(for: account.uid)
        } catch {
            Logger.friends.error("Reading pinned keys failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pin(_ key: PinnedKey?, for uid: String) {
        do {
            try pins.setPin(key, forFriend: uid, account: account.uid)
            pinned[uid] = key
        } catch {
            Logger.friends.error("Saving a pinned key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Profile

    /// Shares the profile with a friend if they don't have it sealed to both current keys.
    private func syncProfile(to uid: String, identity: PublicIdentity) async {
        do {
            let outgoing = try await backend.outgoingShare(from: account.uid, to: uid)
            guard ProfileSharing.needsRepublish(outgoing, myKeyId: account.identity.publicIdentity.keyId, friendKeyId: identity.keyId) else {
                return
            }
            try await ProfileSharing(friends: backend).publish(account.profile, from: account, to: uid, identity: identity)
        } catch {
            Logger.friends.error("Sharing the profile with a friend failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func shareProfile(_ profile: Profile) async {
        account.profile = profile
        for (uid, identity) in identities where friendUIDs.contains(uid) {
            do {
                try await ProfileSharing(friends: backend).publish(profile, from: account, to: uid, identity: identity)
            } catch {
                Logger.friends.error("Sharing the updated profile failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Actions

    func createInvite() async throws -> InviteLink {
        try await inviteFlow.createInvite(for: account)
    }

    func acceptInvite(_ link: InviteLink) async throws {
        _ = try await inviteFlow.accept(link, as: account)
        // The flow pinned the inviter's key; pick that up before their key loads.
        reloadPins()
        emit()
    }

    func removeFriend(_ id: Friend.ID) async throws {
        try await backend.removeFriend(id)
        pin(nil, for: id)
        identities[id] = nil
        identityRequests[id] = nil
    }

    func markKeyVerified(_ id: Friend.ID) throws {
        try setTrust(.compared, for: id)
    }

    func acceptKeyChange(_ id: Friend.ID) throws {
        try setTrust(.firstUse, for: id)
    }

    private func setTrust(_ trust: PinnedKey.Trust, for id: Friend.ID) throws {
        guard let identity = identities[id] else { return }
        let key = PinnedKey(keyId: identity.keyId, trust: trust)
        try pins.setPin(key, forFriend: id, account: account.uid)
        pinned[id] = key
        emit()
    }
}
