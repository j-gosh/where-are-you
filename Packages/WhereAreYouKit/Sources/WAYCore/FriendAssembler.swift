//
//  FriendAssembler.swift
//  WAYCore
//

import Foundation

/// One friend as the signed-in user sees them, after decrypting what they shared.
public struct FriendRecord: Sendable, Equatable {
    public enum KeyStatus: Sendable, Hashable {
        /// Their public key hasn't loaded yet.
        case unknown
        case trusted(PinnedKey.Trust)
        /// Their published key differs from the pinned one: they reset it, or someone swapped it.
        case changed
    }

    public enum Problem: Sendable, Hashable {
        /// They haven't shared their profile with this user yet, e.g. right after accepting.
        case waitingForProfile
        /// Their public key couldn't be loaded yet.
        case keyUnavailable
        /// What they shared was sealed with a key one of you has since replaced. They re-seal it
        /// once their app sees the new key.
        case waitingForNewKey
        /// Couldn't be decrypted or wasn't valid.
        case unreadable
    }

    public let uid: String
    public var profile: Profile?
    public var location: SharedLocation?
    public var isSharingLocation: Bool
    public var identity: PublicIdentity?
    public var keyStatus: KeyStatus
    /// Why `profile` is missing, when it is.
    public var problem: Problem?

    public init(uid: String, profile: Profile?, location: SharedLocation?, isSharingLocation: Bool, identity: PublicIdentity?, keyStatus: KeyStatus, problem: Problem?) {
        self.uid = uid
        self.profile = profile
        self.location = location
        self.isSharingLocation = isSharingLocation
        self.identity = identity
        self.keyStatus = keyStatus
        self.problem = problem
    }
}

/// Combines friendships, shares, public keys and pins into `FriendRecord`s.
public enum FriendAssembler {
    public static func assemble(
        friendUIDs: Set<String>,
        shares: [String: ShareDocument],
        identities: [String: PublicIdentity],
        pins: [String: PinnedKey],
        account: Account
    ) -> [FriendRecord] {
        friendUIDs.sorted().map { uid in
            record(uid: uid, share: shares[uid], identity: identities[uid], pin: pins[uid], account: account)
        }
    }

    static func record(uid: String, share: ShareDocument?, identity: PublicIdentity?, pin: PinnedKey?, account: Account) -> FriendRecord {
        var record = FriendRecord(
            uid: uid,
            profile: nil,
            location: nil,
            isSharingLocation: share?.isSharingLocation ?? false,
            identity: identity,
            keyStatus: keyStatus(identity: identity, pin: pin),
            problem: nil
        )
        guard let share else {
            record.problem = .waitingForProfile
            return record
        }
        guard let identity else {
            record.problem = .keyUnavailable
            return record
        }

        func open<Payload: SealablePayload>(_ type: Payload.Type, _ box: SealedBox) throws -> Payload {
            try Sealing.open(type, from: box, sender: identity, senderUid: uid, recipient: account.identity, recipientUid: account.uid)
        }

        do {
            record.profile = try open(Profile.self, share.profile)
        } catch CryptoError.keyMismatch {
            record.problem = .waitingForNewKey
            return record
        } catch {
            record.problem = .unreadable
            return record
        }
        if share.isSharingLocation, let box = share.location {
            // An unreadable location just shows as unavailable; the profile is still useful.
            record.location = try? open(SharedLocation.self, box)
        }
        return record
    }

    static func keyStatus(identity: PublicIdentity?, pin: PinnedKey?) -> FriendRecord.KeyStatus {
        guard let identity else { return .unknown }
        guard let pin else { return .trusted(.firstUse) }
        return pin.keyId == identity.keyId ? .trusted(pin.trust) : .changed
    }
}
