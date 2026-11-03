//
//  Invites.swift
//  WAYCore
//

import Foundation

/// Creating and accepting invites. Shared by the app and the Messages extension.
public struct InviteFlow: Sendable {
    /// How long an invite stays valid. The rules allow at most 7 days.
    public static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    private let friends: FriendsBackend
    private let accounts: AccountBackend
    private let pins: PinnedKeyStore

    public init(friends: FriendsBackend, accounts: AccountBackend, pins: PinnedKeyStore) {
        self.friends = friends
        self.accounts = accounts
        self.pins = pins
    }

    public func createInvite(for account: Account, now: Date = .now) async throws -> InviteLink {
        let link = try InviteLink(
            token: InviteLink.generateToken(),
            inviterKeyId: account.identity.publicIdentity.keyId,
            inviterName: account.profile.displayName
        )
        try await friends.createInvite(
            token: link.token,
            inviterUid: account.uid,
            inviterKeyId: link.inviterKeyId,
            expiresAt: now.addingTimeInterval(Self.lifetime)
        )
        return link
    }

    /// Accepts an invite and returns the new friend's uid.
    ///
    /// Before accepting, checks that the key the server publishes for the inviter matches the
    /// key ID that came with the invite. That ID travelled over Messages, which the server can't
    /// touch, so a match means the server didn't swap in a key of its own. Afterwards, pins the
    /// inviter's key and shares this account's profile with them.
    public func accept(_ link: InviteLink, as account: Account, now: Date = .now) async throws -> String {
        guard let invite = try await friends.invite(token: link.token), invite.expiresAt > now else {
            throw InviteError.expiredOrUsed
        }
        guard invite.inviterUid != account.uid, link.inviterKeyId != account.identity.publicIdentity.keyId else {
            throw InviteError.ownInvite
        }
        guard let inviterIdentity = try await accounts.publicIdentity(of: invite.inviterUid) else {
            throw InviteError.inviterNotSetUp
        }
        guard inviterIdentity.keyId == link.inviterKeyId, invite.inviterKeyId == link.inviterKeyId else {
            throw InviteError.keyMismatch
        }

        let friendUid = try await friends.acceptInvite(token: link.token)
        guard friendUid == invite.inviterUid else {
            throw InviteError.keyMismatch
        }

        try pins.setPin(PinnedKey(keyId: inviterIdentity.keyId, trust: .invite), forFriend: friendUid, account: account.uid)
        try await ProfileSharing(friends: friends).publish(account.profile, from: account, to: friendUid, identity: inviterIdentity)
        return friendUid
    }
}

/// Seals the user's profile for each friend.
public struct ProfileSharing: Sendable {
    private let friends: FriendsBackend

    public init(friends: FriendsBackend) {
        self.friends = friends
    }

    public func publish(_ profile: Profile, from account: Account, to friendUid: String, identity: PublicIdentity) async throws {
        let box = try Sealing.seal(profile, from: account.identity, senderUid: account.uid, to: identity, recipientUid: friendUid)
        try await friends.publishProfile(box, from: account.uid, to: friendUid)
    }

    /// Whether what the user shared with a friend is missing, or sealed with a key either of them
    /// no longer uses.
    public static func needsRepublish(_ share: ShareDocument?, myKeyId: String, friendKeyId: String) -> Bool {
        guard let share else { return true }
        return share.profile.senderKeyId != myKeyId || share.profile.recipientKeyId != friendKeyId
    }
}

/// Loads an account that's already fully set up on this device. The Messages extension uses it;
/// creating keys and profiles is left to the app.
public enum AccountLoader {
    /// `nil` when this device lacks the published key, or there's no readable profile yet.
    public static func loadExisting(uid: String, keyStore: KeyStore, accounts: AccountBackend) async throws -> Account? {
        guard let identity = try keyStore.identityKey(for: uid),
              let published = try await accounts.publicIdentity(of: uid),
              published == identity.publicIdentity,
              let box = try await accounts.ownProfileBox(for: uid),
              let profile = try? Sealing.open(Profile.self, from: box, sender: identity.publicIdentity, senderUid: uid, recipient: identity, recipientUid: uid)
        else {
            return nil
        }
        return Account(uid: uid, identity: identity, profile: profile)
    }
}
