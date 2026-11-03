//
//  FirebaseSharingBackend.swift
//  WAYFirebase
//

import FirebaseFirestore
import Foundation
import WAYCore

public struct FirebaseSharingBackend: SharingBackend {
    public init() {}

    private var db: Firestore {
        Firestore.firestore()
    }

    public func sharingSettings(of uid: String) -> AsyncThrowingStream<SharingSettings, Error> {
        listen(to: db.privateDocument("sharing", of: uid)) { snapshot in
            try Self.settings(from: snapshot)
        }
    }

    public func fetchSharingSettings(of uid: String) async throws -> SharingSettings {
        try Self.settings(from: try await db.privateDocument("sharing", of: uid).getDocument())
    }

    public func saveSharingSettings(_ settings: SharingSettings, for uid: String) async throws {
        try await db.privateDocument("sharing", of: uid).setData([
            "isEnabled": settings.isEnabled,
            "friendUIDs": settings.friendUIDs.sorted(),
            "activeDeviceId": settings.activeDeviceId ?? NSNull(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    public func writeShares(_ shares: [OutgoingShare], from uid: String) async throws {
        guard !shares.isEmpty else { return }
        let encoder = Firestore.Encoder()
        let batch = db.batch()
        for share in shares {
            // Whole-document writes: each share is valid on its own (see LocationSharer).
            batch.setData([
                "profile": try encoder.encode(share.profile),
                "location": try share.location.map { try encoder.encode($0) } ?? NSNull(),
                "isSharingLocation": share.isSharingLocation,
                "updatedAt": FieldValue.serverTimestamp(),
            ], forDocument: db.shareDocument(recipient: share.recipientUid, sender: uid))
        }
        try await batch.commit()
    }

    private static func settings(from snapshot: DocumentSnapshot) throws -> SharingSettings {
        guard snapshot.exists else { return .off }
        let fields = try snapshot.data(as: SharingFields.self)
        return SharingSettings(isEnabled: fields.isEnabled, friendUIDs: Set(fields.friendUIDs), activeDeviceId: fields.activeDeviceId)
    }
}

/// `users/{uid}/private/sharing`.
private struct SharingFields: Decodable {
    var isEnabled: Bool
    var friendUIDs: [String]
    var activeDeviceId: String?
}
