//
//  FirebaseAccountBackend.swift
//  WAYFirebase
//
//  Document layout and access rules: firebase/firestore.rules.
//

import FirebaseFirestore
import FirebaseFunctions
import Foundation
import WAYCore

public struct FirebaseAccountBackend: AccountBackend {
    public init() {}

    private var db: Firestore {
        Firestore.firestore()
    }

    private func userDocument(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    private func profileDocument(_ uid: String) -> DocumentReference {
        userDocument(uid).collection("private").document("profile")
    }

    public func publicIdentity(of uid: String) async throws -> PublicIdentity? {
        let snapshot = try await userDocument(uid).getDocument()
        guard snapshot.exists else { return nil }
        guard let publicKey = snapshot.get("publicKey") as? Data else {
            throw CryptoError.invalidPublicKey
        }
        // The stored keyId is for rules and invites; the identity recomputes it from the key.
        return try PublicIdentity(rawRepresentation: publicKey)
    }

    public func publishIdentity(_ identity: PublicIdentity, for uid: String) async throws {
        try await userDocument(uid).setData([
            "publicKey": identity.rawRepresentation,
            "keyId": identity.keyId,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    public func ownProfileBox(for uid: String) async throws -> SealedBox? {
        let snapshot = try await profileDocument(uid).getDocument()
        guard snapshot.exists else { return nil }
        return try snapshot.data(as: ProfileDocument.self).box
    }

    public func saveOwnProfileBox(_ box: SealedBox, for uid: String) async throws {
        // Encode first, then await the server, so a rejected write surfaces as an error.
        let fields = try Firestore.Encoder().encode(ProfileDocument(box: box))
        try await profileDocument(uid).setData(fields)
    }

    public func deleteAccount() async throws {
        // See firebase/functions/src/index.ts.
        _ = try await Functions.functions().httpsCallable("deleteAccount").call()
    }
}

private struct ProfileDocument: Codable {
    var box: SealedBox
    @ServerTimestamp var updatedAt: Timestamp?
}
