//
//  FirebaseFriendsBackend.swift
//  WAYFirebase
//
//  Document layout and access rules: firebase/firestore.rules. Callable functions:
//  firebase/functions/src.
//

import FirebaseFirestore
import FirebaseFunctions
import Foundation
import WAYCore

public enum FirebaseFriendsBackendError: Error {
    /// A function returned something other than what the app expects.
    case unexpectedResponse
}

public struct FirebaseFriendsBackend: FriendsBackend {
    public init() {}

    private var db: Firestore {
        Firestore.firestore()
    }

    private func shareDocument(recipient: String, sender: String) -> DocumentReference {
        db.collection("inboxes").document(recipient).collection("shares").document(sender)
    }

    // MARK: Listening

    public func friendUIDs(of uid: String) -> AsyncThrowingStream<Set<String>, Error> {
        listen(to: db.collection("friendships").whereField("members", arrayContains: uid)) { snapshot in
            let members = snapshot.documents.flatMap { ($0.get("members") as? [String]) ?? [] }
            return Set(members.filter { $0 != uid })
        }
    }

    public func incomingShares(for uid: String) -> AsyncThrowingStream<[ShareDocument], Error> {
        listen(to: db.collection("inboxes").document(uid).collection("shares")) { snapshot in
            snapshot.documents.compactMap { document in
                do {
                    return try document.data(as: ShareFields.self).share(from: document.documentID)
                } catch {
                    // One malformed share shouldn't hide every other friend.
                    Log.firebase.error("Skipping malformed share: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }
    }

    // MARK: Shares

    public func outgoingShare(from uid: String, to friendUid: String) async throws -> ShareDocument? {
        let snapshot = try await shareDocument(recipient: friendUid, sender: uid).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: ShareFields.self).share(from: uid)
    }

    public func publishProfile(_ box: SealedBox, from uid: String, to friendUid: String) async throws {
        let reference = shareDocument(recipient: friendUid, sender: uid)
        let profile = try Firestore.Encoder().encode(box)
        if try await reference.getDocument().exists {
            // Leave the location fields alone: location sharing owns them.
            try await reference.updateData([
                "profile": profile,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
        } else {
            try await reference.setData([
                "profile": profile,
                "location": NSNull(),
                "isSharingLocation": false,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
        }
    }

    // MARK: Invites

    public func createInvite(token: String, inviterUid: String, inviterKeyId: String, expiresAt: Date) async throws {
        try await db.collection("invites").document(token).setData([
            "inviterUid": inviterUid,
            "inviterKeyId": inviterKeyId,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: expiresAt),
        ])
    }

    public func invite(token: String) async throws -> InviteDocument? {
        let snapshot = try await db.collection("invites").document(token).getDocument()
        guard snapshot.exists else { return nil }
        guard let inviterUid = snapshot.get("inviterUid") as? String,
              let inviterKeyId = snapshot.get("inviterKeyId") as? String,
              let expiresAt = snapshot.get("expiresAt") as? Timestamp else {
            throw FirebaseFriendsBackendError.unexpectedResponse
        }
        return InviteDocument(inviterUid: inviterUid, inviterKeyId: inviterKeyId, expiresAt: expiresAt.dateValue())
    }

    public func acceptInvite(token: String) async throws -> String {
        do {
            let result = try await Functions.functions().httpsCallable("acceptInvite").call(["token": token])
            guard let data = result.data as? [String: Any], let inviterUid = data["inviterUid"] as? String else {
                throw FirebaseFriendsBackendError.unexpectedResponse
            }
            return inviterUid
        } catch let error as NSError where error.domain == FunctionsErrorDomain {
            throw Self.inviteError(from: error) ?? error
        }
    }

    public func removeFriend(_ friendUid: String) async throws {
        _ = try await Functions.functions().httpsCallable("removeFriend").call(["friendUid": friendUid])
    }

    /// Maps acceptInvite's documented failures (see firebase/functions/src/friendships.ts).
    static func inviteError(from error: NSError) -> InviteError? {
        let details = error.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        switch (FunctionsErrorCode(rawValue: error.code), details?["reason"] as? String) {
        case (.notFound?, _), (_, "expired"?):
            return .expiredOrUsed
        case (_, "own-invite"?):
            return .ownInvite
        case (.resourceExhausted?, _):
            return .friendLimitReached
        default:
            return nil
        }
    }
}

/// `inboxes/{recipient}/shares/{sender}`.
private struct ShareFields: Codable {
    var profile: SealedBox
    var location: SealedBox?
    var isSharingLocation: Bool
    @ServerTimestamp var updatedAt: Timestamp?

    func share(from senderUid: String) -> ShareDocument {
        ShareDocument(senderUid: senderUid, profile: profile, location: location, isSharingLocation: isSharingLocation)
    }
}
