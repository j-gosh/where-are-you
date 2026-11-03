//
//  Friends.swift
//  WAYCore
//
//  Friendships, invites and what friends share, as the backend stores them.
//  Layout and access rules: firebase/firestore.rules.
//

import Foundation

/// A signed-in user whose key and profile are set up.
public struct Account: Sendable {
    public let uid: String
    public let identity: IdentityKey
    public var profile: Profile

    public init(uid: String, identity: IdentityKey, profile: Profile) {
        self.uid = uid
        self.identity = identity
        self.profile = profile
    }
}

/// What one friend shares with the signed-in user: `inboxes/{recipient}/shares/{sender}`.
public struct ShareDocument: Sendable, Equatable {
    public var senderUid: String
    /// The sender's profile, sealed for the recipient.
    public var profile: SealedBox
    /// The sender's latest location, sealed for the recipient. `nil` when not sharing.
    public var location: SealedBox?
    public var isSharingLocation: Bool

    public init(senderUid: String, profile: SealedBox, location: SealedBox?, isSharingLocation: Bool) {
        self.senderUid = senderUid
        self.profile = profile
        self.location = location
        self.isSharingLocation = isSharingLocation
    }
}

/// `invites/{token}`.
public struct InviteDocument: Sendable, Equatable {
    public var inviterUid: String
    public var inviterKeyId: String
    public var expiresAt: Date

    public init(inviterUid: String, inviterKeyId: String, expiresAt: Date) {
        self.inviterUid = inviterUid
        self.inviterKeyId = inviterKeyId
        self.expiresAt = expiresAt
    }
}

public enum InviteError: Error, Equatable {
    /// Expired, already accepted, or never existed.
    case expiredOrUsed
    case ownInvite
    /// One of the two people already has the maximum number of friends.
    case friendLimitReached
    /// The inviter's published key doesn't match the key in the invite: someone may have
    /// tampered with it. Nothing was accepted.
    case keyMismatch
    /// The inviter hasn't finished setting up their account.
    case inviterNotSetUp
}

extension InviteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .expiredOrUsed:
            String(localized: "This invite has expired or was already used. Ask for a new one.")
        case .ownInvite:
            String(localized: "This is your own invite. Send it to a friend instead.")
        case .friendLimitReached:
            String(localized: "One of you already has the maximum number of friends.")
        case .keyMismatch:
            String(localized: "This invite doesn't match the inviter's encryption key, so it wasn't accepted. Ask them to send a new invite.")
        case .inviterNotSetUp:
            String(localized: "The person who invited you hasn't finished setting up. Try again later.")
        }
    }
}

public protocol FriendsBackend: Sendable {
    /// The user's friends' uids immediately, then after every change.
    func friendUIDs(of uid: String) -> AsyncThrowingStream<Set<String>, Error>
    /// Everything friends share with the user, immediately and after every change.
    func incomingShares(for uid: String) -> AsyncThrowingStream<[ShareDocument], Error>
    /// What the user shares with one friend, to check whether it needs re-sealing.
    func outgoingShare(from uid: String, to friendUid: String) async throws -> ShareDocument?
    /// Creates the share with a friend if needed, or replaces just its profile.
    func publishProfile(_ box: SealedBox, from uid: String, to friendUid: String) async throws

    func createInvite(token: String, inviterUid: String, inviterKeyId: String, expiresAt: Date) async throws
    func invite(token: String) async throws -> InviteDocument?
    /// Becomes friends with the inviter and uses up the invite. Returns the inviter's uid.
    /// Throws `InviteError` for invites that can't be accepted.
    func acceptInvite(token: String) async throws -> String
    /// Ends the friendship and deletes what each side shared with the other.
    func removeFriend(_ friendUid: String) async throws
}
