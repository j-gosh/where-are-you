//
//  Alerts.swift
//  WAYCore
//
//  Arrive/leave alerts. The requester seals an `AlertRequest` for the friend being watched; the
//  friend's device monitors the place and, when it fires, seals an `AlertEvent` back to the
//  requester. The server only relays ciphertext and pushes.
//

import Foundation

/// `inboxes/{target}/alertRequests/{id}`.
public struct AlertRequestDocument: Equatable, Sendable {
    public var id: String
    public var requesterUid: String
    public var targetUid: String
    /// Sealed for the target.
    public var payload: SealedBox
    /// The same request sealed to the requester, so they can list what they've set.
    public var requesterCopy: SealedBox
    /// Server time. `nil` until the write reaches the server.
    public var createdAt: Date?

    public init(id: String, requesterUid: String, targetUid: String, payload: SealedBox, requesterCopy: SealedBox, createdAt: Date?) {
        self.id = id
        self.requesterUid = requesterUid
        self.targetUid = targetUid
        self.payload = payload
        self.requesterCopy = requesterCopy
        self.createdAt = createdAt
    }
}

/// `users/{uid}/private/prefs`. Receiving is enforced by the notification function; sending
/// (allowing alerts on yourself) by the watched person's device.
public struct AlertPreferences: Codable, Equatable, Sendable {
    public var receiveAlerts: Bool
    public var mutedAlertSenders: Set<String>
    public var allowAlertsOnMe: Bool
    public var blockedAlertRequesters: Set<String>

    public init(receiveAlerts: Bool = true, mutedAlertSenders: Set<String> = [], allowAlertsOnMe: Bool = true, blockedAlertRequesters: Set<String> = []) {
        self.receiveAlerts = receiveAlerts
        self.mutedAlertSenders = mutedAlertSenders
        self.allowAlertsOnMe = allowAlertsOnMe
        self.blockedAlertRequesters = blockedAlertRequesters
    }

    public func allowsAlerts(from requesterUid: String) -> Bool {
        allowAlertsOnMe && !blockedAlertRequesters.contains(requesterUid)
    }
}

public protocol AlertsBackend: Sendable {
    /// Requests friends have set on `targetUid`.
    func alertRequests(on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error>
    /// Requests `requesterUid` has set on one friend.
    func alertRequests(setBy requesterUid: String, on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error>
    func createAlertRequest(_ document: AlertRequestDocument) async throws
    func deleteAlertRequest(id: String, on targetUid: String) async throws
    func alertPreferences(of uid: String) -> AsyncThrowingStream<AlertPreferences, Error>
    func fetchAlertPreferences(of uid: String) async throws -> AlertPreferences
    func saveAlertPreferences(_ preferences: AlertPreferences, for uid: String) async throws
    /// Queues a push to `toUid`. Only the notification function reads these.
    func postNotificationEvent(from fromUid: String, to toUid: String, payload: SealedBox, expiresAt: Date) async throws
}

/// An alert on the user that their device is watching for. Stored on device, so geofence
/// events can be handled after a background relaunch without network reads.
public struct MonitoredAlert: Codable, Equatable, Sendable {
    public var request: AlertRequest
    public var requesterUid: String
    /// The requester's public key, to seal the event for them.
    public var requesterKey: Data

    public var id: String { request.id }

    public init(request: AlertRequest, requesterUid: String, requesterKey: Data) {
        self.request = request
        self.requesterUid = requesterUid
        self.requesterKey = requesterKey
    }
}

/// An alert the user set on a friend, decrypted from their own copy.
public struct SetAlert: Equatable, Sendable, Identifiable {
    public var request: AlertRequest
    public var targetUid: String

    public var id: String { request.id }
}

public enum GeofenceState: String, Codable, Sendable {
    case inside
    case outside
}

public enum AlertPlanner {
    /// iOS monitors at most 20 regions per app.
    public static let monitoringLimit = 20

    public struct Plan: Equatable, Sendable {
        /// Oldest first, within the limit.
        public var monitored: [MonitoredAlert]
        /// Allowed but over the limit.
        public var overLimit: Int
        /// Couldn't be decrypted (unknown or replaced keys).
        public var unreadable: Int
    }

    /// Decrypts the requests set on the user, drops ones they don't allow, and keeps the oldest
    /// within the monitoring limit.
    public static func plan(
        documents: [AlertRequestDocument],
        account: Account,
        identities: [String: PublicIdentity],
        preferences: AlertPreferences,
        limit: Int = monitoringLimit
    ) -> Plan {
        var alerts: [(alert: MonitoredAlert, createdAt: Date?)] = []
        var unreadable = 0
        for document in documents where document.targetUid == account.uid && preferences.allowsAlerts(from: document.requesterUid) {
            guard let identity = identities[document.requesterUid],
                  let request = try? Sealing.open(AlertRequest.self, from: document.payload, sender: identity, senderUid: document.requesterUid, recipient: account.identity, recipientUid: account.uid),
                  request.id == document.id else {
                unreadable += 1
                continue
            }
            alerts.append((MonitoredAlert(request: request, requesterUid: document.requesterUid, requesterKey: identity.rawRepresentation), document.createdAt))
        }
        alerts.sort { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?) where l != r: l < r
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.alert.id < rhs.alert.id
            }
        }
        return Plan(monitored: alerts.prefix(limit).map(\.alert), overLimit: max(0, alerts.count - limit), unreadable: unreadable)
    }

    /// Decrypts the requester's own copies of alerts they set.
    public static func setAlerts(documents: [AlertRequestDocument], account: Account) -> [SetAlert] {
        documents.compactMap { document in
            guard document.requesterUid == account.uid,
                  let request = try? Sealing.open(AlertRequest.self, from: document.requesterCopy, sender: account.identity.publicIdentity, senderUid: account.uid, recipient: account.identity, recipientUid: account.uid),
                  request.id == document.id else { return nil }
            return SetAlert(request: request, targetUid: document.targetUid)
        }
        .sorted { $0.request.placeName.localizedStandardCompare($1.request.placeName) == .orderedAscending }
    }

    /// Only real transitions notify. The first state seen for a region (on creation or after a
    /// relaunch) is just recorded, so "arrive" doesn't fire when you're already there.
    public static func shouldNotify(trigger: AlertTrigger, previous: GeofenceState?, current: GeofenceState) -> Bool {
        switch trigger {
        case .arrive: previous == .outside && current == .inside
        case .leave: previous == .inside && current == .outside
        }
    }

    /// The event to send the requester when an alert fires.
    public static func sealedEvent(for alert: MonitoredAlert, account: Account, at date: Date) throws -> SealedBox {
        let requester = try PublicIdentity(rawRepresentation: alert.requesterKey)
        let event = AlertEvent(alertId: alert.id, placeName: alert.request.placeName, trigger: alert.request.trigger, occurredAt: date)
        return try Sealing.seal(event, from: account.identity, senderUid: account.uid, to: requester, recipientUid: alert.requesterUid)
    }

    /// The document for a new alert on a friend, with the requester's own copy.
    public static func requestDocument(_ request: AlertRequest, from account: Account, to targetUid: String, identity: PublicIdentity) throws -> AlertRequestDocument {
        AlertRequestDocument(
            id: request.id,
            requesterUid: account.uid,
            targetUid: targetUid,
            payload: try Sealing.seal(request, from: account.identity, senderUid: account.uid, to: identity, recipientUid: targetUid),
            requesterCopy: try Sealing.seal(request, from: account.identity, senderUid: account.uid, to: account.identity.publicIdentity, recipientUid: account.uid),
            createdAt: nil
        )
    }
}
