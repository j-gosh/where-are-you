//
//  Friend.swift
//  where-are-you
//

import CoreLocation
import Foundation
import WAYCore

/// A person who shares their location with the current user.
struct Friend: Identifiable, Hashable, Sendable {
    /// The friend's uid.
    let id: String
    var displayName: String
    var avatar: Avatar
    /// `nil` when the friend isn't sharing right now, or their latest update couldn't be read.
    var location: SharedLocation?
    /// Whether they share their location with the user at all.
    var isSharingLocation = false
    /// Their public key, for the security code. `nil` until loaded, and in fixtures.
    var identity: PublicIdentity?
    var keyStatus: FriendRecord.KeyStatus = .unknown
    /// Why their profile couldn't be shown, if it couldn't.
    var problem: FriendRecord.Problem?
}

extension Friend {
    init(_ record: FriendRecord) {
        self.init(
            id: record.uid,
            displayName: record.profile?.displayName ?? String(localized: "Friend"),
            avatar: record.profile?.avatar ?? Avatar(emoji: nil, color: .blue),
            location: record.location,
            isSharingLocation: record.isSharingLocation,
            identity: record.identity,
            keyStatus: record.keyStatus,
            problem: record.problem
        )
    }
}

extension SharedLocation {
    /// Updates older than this are shown as stale.
    static let staleInterval: TimeInterval = 60 * 60

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(timestamp) > Self.staleInterval
    }
}
