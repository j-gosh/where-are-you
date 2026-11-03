//
//  FirebaseAlertsBackend.swift
//  WAYFirebase
//

import FirebaseFirestore
import Foundation
import WAYCore

public struct FirebaseAlertsBackend: AlertsBackend {
    public init() {}

    private var db: Firestore {
        Firestore.firestore()
    }

    private func alertRequests(of targetUid: String) -> CollectionReference {
        db.collection("inboxes").document(targetUid).collection("alertRequests")
    }

    public func alertRequests(on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error> {
        listen(to: alertRequests(of: targetUid)) { snapshot in
            Self.documents(from: snapshot, targetUid: targetUid)
        }
    }

    public func alertRequests(setBy requesterUid: String, on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error> {
        listen(to: alertRequests(of: targetUid).whereField("requesterUid", isEqualTo: requesterUid)) { snapshot in
            Self.documents(from: snapshot, targetUid: targetUid)
        }
    }

    public func createAlertRequest(_ document: AlertRequestDocument) async throws {
        let encoder = Firestore.Encoder()
        try await alertRequests(of: document.targetUid).document(document.id).setData([
            "requesterUid": document.requesterUid,
            "payload": try encoder.encode(document.payload),
            "requesterCopy": try encoder.encode(document.requesterCopy),
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    public func deleteAlertRequest(id: String, on targetUid: String) async throws {
        try await alertRequests(of: targetUid).document(id).delete()
    }

    public func alertPreferences(of uid: String) -> AsyncThrowingStream<AlertPreferences, Error> {
        listen(to: db.privateDocument("prefs", of: uid)) { snapshot in
            try Self.preferences(from: snapshot)
        }
    }

    public func fetchAlertPreferences(of uid: String) async throws -> AlertPreferences {
        try Self.preferences(from: try await db.privateDocument("prefs", of: uid).getDocument())
    }

    public func saveAlertPreferences(_ preferences: AlertPreferences, for uid: String) async throws {
        try await db.privateDocument("prefs", of: uid).setData([
            "receiveAlerts": preferences.receiveAlerts,
            "mutedAlertSenders": preferences.mutedAlertSenders.sorted(),
            "allowAlertsOnMe": preferences.allowAlertsOnMe,
            "blockedAlertRequesters": preferences.blockedAlertRequesters.sorted(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    public func postNotificationEvent(from fromUid: String, to toUid: String, payload: SealedBox, expiresAt: Date) async throws {
        try await db.collection("notificationEvents").addDocument(data: [
            "fromUid": fromUid,
            "toUid": toUid,
            "payload": try Firestore.Encoder().encode(payload),
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: expiresAt),
        ])
    }

    private static func documents(from snapshot: QuerySnapshot, targetUid: String) -> [AlertRequestDocument] {
        snapshot.documents.compactMap { document in
            do {
                let fields = try document.data(as: AlertRequestFields.self)
                return AlertRequestDocument(
                    id: document.documentID,
                    requesterUid: fields.requesterUid,
                    targetUid: targetUid,
                    payload: fields.payload,
                    requesterCopy: fields.requesterCopy,
                    createdAt: fields.createdAt?.dateValue()
                )
            } catch {
                Log.firebase.error("Skipping malformed alert request: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private static func preferences(from snapshot: DocumentSnapshot) throws -> AlertPreferences {
        guard snapshot.exists else { return AlertPreferences() }
        let fields = try snapshot.data(as: PreferenceFields.self)
        return AlertPreferences(
            receiveAlerts: fields.receiveAlerts,
            mutedAlertSenders: Set(fields.mutedAlertSenders),
            allowAlertsOnMe: fields.allowAlertsOnMe ?? true,
            blockedAlertRequesters: Set(fields.blockedAlertRequesters ?? [])
        )
    }
}

/// `inboxes/{target}/alertRequests/{id}`.
private struct AlertRequestFields: Codable {
    var requesterUid: String
    var payload: SealedBox
    var requesterCopy: SealedBox
    @ServerTimestamp var createdAt: Timestamp?
}

/// `users/{uid}/private/prefs`.
private struct PreferenceFields: Decodable {
    var receiveAlerts: Bool
    var mutedAlertSenders: [String]
    var allowAlertsOnMe: Bool?
    var blockedAlertRequesters: [String]?
}
