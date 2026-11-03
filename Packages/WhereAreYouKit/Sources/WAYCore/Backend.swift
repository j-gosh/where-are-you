//
//  Backend.swift
//  WAYCore
//
//  What the app needs from a backend. WAYFirebase implements these with Firebase;
//  tests and UI tests use in-memory fakes.
//

import Foundation

/// The result of a successful Sign in with Apple request.
public struct AppleCredential: Sendable, Equatable {
    public var idToken: String
    /// The nonce whose SHA-256 was sent to Apple. `nil` only for emulator test accounts.
    public var rawNonce: String?
    /// Needed to revoke the Apple token when deleting the account.
    public var authorizationCode: String?
    /// Apple only provides the name the first time the user signs in to the app.
    public var fullName: PersonNameComponents?

    public init(idToken: String, rawNonce: String?, authorizationCode: String?, fullName: PersonNameComponents?) {
        self.idToken = idToken
        self.rawNonce = rawNonce
        self.authorizationCode = authorizationCode
        self.fullName = fullName
    }
}

public protocol AuthBackend: Sendable {
    /// The signed-in user's ID immediately, then after every change. `nil` means signed out.
    func userIDs() -> AsyncStream<String?>
    /// Returns the user ID.
    func signIn(with credential: AppleCredential) async throws -> String
    /// Fresh proof of identity, required before deleting the account.
    func reauthenticate(with credential: AppleCredential) async throws
    /// Tells Apple to forget the app's link to this Apple ID (required when deleting accounts).
    func revokeAppleToken(authorizationCode: String) async throws
    func signOut() throws
}

public protocol AccountBackend: Sendable {
    /// The public key a user has published, or `nil` if they haven't yet.
    func publicIdentity(of uid: String) async throws -> PublicIdentity?
    /// Publishes (or replaces) the signed-in user's public key.
    func publishIdentity(_ identity: PublicIdentity, for uid: String) async throws
    /// The user's own profile, sealed to their own key.
    func ownProfileBox(for uid: String) async throws -> SealedBox?
    func saveOwnProfileBox(_ box: SealedBox, for uid: String) async throws
    /// Deletes everything stored for the signed-in user, then the account itself.
    func deleteAccount() async throws
}
