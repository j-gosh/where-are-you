//
//  FirebaseAuthBackend.swift
//  WAYFirebase
//

import FirebaseAuth
import Foundation
import WAYCore

public enum FirebaseAuthBackendError: Error, Equatable {
    /// An action that needs a signed-in user ran without one.
    case notSignedIn
}

/// Firebase Auth with Sign in with Apple as the only provider.
public struct FirebaseAuthBackend: AuthBackend {
    public init() {}

    public func userIDs() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let handle = Auth.auth().addStateDidChangeListener { _, user in
                continuation.yield(user?.uid)
            }
            let registration = ListenerHandle(handle)
            continuation.onTermination = { _ in
                Auth.auth().removeStateDidChangeListener(registration.handle)
            }
        }
    }

    public func signIn(with credential: AppleCredential) async throws -> String {
        try await Auth.auth().signIn(with: credential.firebaseCredential).user.uid
    }

    public func reauthenticate(with credential: AppleCredential) async throws {
        guard let user = Auth.auth().currentUser else {
            throw FirebaseAuthBackendError.notSignedIn
        }
        _ = try await user.reauthenticate(with: credential.firebaseCredential)
    }

    public func revokeAppleToken(authorizationCode: String) async throws {
        try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
    }

    public func signOut() throws {
        try Auth.auth().signOut()
    }
}

private extension AppleCredential {
    var firebaseCredential: AuthCredential {
        OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: fullName)
    }
}

/// Auth's listener handle is an opaque token that's only passed back to Auth.
private struct ListenerHandle: @unchecked Sendable {
    let handle: NSObjectProtocol

    init(_ handle: NSObjectProtocol) {
        self.handle = handle
    }
}
