//
//  Sharing.swift
//  WAYCore
//
//  Location sharing: who the user shares with, from which device, and what gets uploaded.
//

import Foundation

/// `users/{uid}/private/sharing`. Private to the user; synced so every device agrees.
public struct SharingSettings: Codable, Equatable, Sendable {
    public static let off = SharingSettings(isEnabled: false, friendUIDs: [], activeDeviceId: nil)

    /// The master "Share My Location" switch.
    public var isEnabled: Bool
    /// Friends the user shares their location with.
    public var friendUIDs: Set<String>
    /// The one device whose location is shared ("Use This iPhone as My Location").
    public var activeDeviceId: String?

    public init(isEnabled: Bool, friendUIDs: Set<String>, activeDeviceId: String?) {
        self.isEnabled = isEnabled
        self.friendUIDs = friendUIDs
        self.activeDeviceId = activeDeviceId
    }

    public func isSharing(with friendUid: String) -> Bool {
        isEnabled && friendUIDs.contains(friendUid)
    }

    /// Whether `deviceId` should upload its location.
    public func uploads(from deviceId: String) -> Bool {
        isEnabled && activeDeviceId == deviceId && !friendUIDs.isEmpty
    }
}

/// One share the user writes for a friend: `inboxes/{recipient}/shares/{user}`.
public struct OutgoingShare: Equatable, Sendable {
    public var recipientUid: String
    public var profile: SealedBox
    /// `nil` stops showing a location.
    public var location: SealedBox?

    public var isSharingLocation: Bool {
        location != nil
    }

    public init(recipientUid: String, profile: SealedBox, location: SealedBox?) {
        self.recipientUid = recipientUid
        self.profile = profile
        self.location = location
    }
}

public protocol SharingBackend: Sendable {
    func sharingSettings(of uid: String) -> AsyncThrowingStream<SharingSettings, Error>
    func fetchSharingSettings(of uid: String) async throws -> SharingSettings
    func saveSharingSettings(_ settings: SharingSettings, for uid: String) async throws
    /// Replaces each share whole, in one batch.
    func writeShares(_ shares: [OutgoingShare], from uid: String) async throws
}

/// When a new reading is worth uploading. Fewer uploads mean less battery and fewer
/// Firestore writes (one per friend per upload).
public struct UploadPolicy: Sendable {
    public var minimumDistance: Double
    public var minimumInterval: TimeInterval
    /// Upload even without movement after this long, so friends see the location is current.
    public var heartbeatInterval: TimeInterval

    public init(minimumDistance: Double = 25, minimumInterval: TimeInterval = 30, heartbeatInterval: TimeInterval = 15 * 60) {
        self.minimumDistance = minimumDistance
        self.minimumInterval = minimumInterval
        self.heartbeatInterval = heartbeatInterval
    }

    public func shouldUpload(_ location: SharedLocation, after last: SharedLocation?) -> Bool {
        guard let last else { return true }
        let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
        if elapsed >= heartbeatInterval {
            return true
        }
        guard elapsed >= minimumInterval else { return false }
        return location.isApproximate != last.isApproximate
            || Self.distance(from: last, to: location) >= minimumDistance
    }

    /// Great-circle distance in meters.
    public static func distance(from a: SharedLocation, to b: SharedLocation) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

/// Builds the shares to write. Each carries a fresh profile copy, so a share is always valid on
/// its own (the rules require a profile).
public enum LocationSharer {
    /// A sealed copy of `location` for each recipient.
    public static func shares(for location: SharedLocation, account: Account, recipients: [String: PublicIdentity]) throws -> [OutgoingShare] {
        try recipients.sorted { $0.key < $1.key }.map { uid, identity in
            OutgoingShare(
                recipientUid: uid,
                profile: try seal(account.profile, account: account, to: uid, identity: identity),
                location: try seal(location, account: account, to: uid, identity: identity)
            )
        }
    }

    /// Shares that stop showing the user's location, keeping their profile.
    public static func stoppedShares(account: Account, recipients: [String: PublicIdentity]) throws -> [OutgoingShare] {
        try recipients.sorted { $0.key < $1.key }.map { uid, identity in
            OutgoingShare(
                recipientUid: uid,
                profile: try seal(account.profile, account: account, to: uid, identity: identity),
                location: nil
            )
        }
    }

    private static func seal<Payload: SealablePayload>(_ payload: Payload, account: Account, to uid: String, identity: PublicIdentity) throws -> SealedBox {
        try Sealing.seal(payload, from: account.identity, senderUid: account.uid, to: identity, recipientUid: uid)
    }
}
