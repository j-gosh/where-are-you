//
//  AppleSignIn.swift
//  where-are-you
//

import AuthenticationServices
import CryptoKit
import UIKit
import WAYCore

/// Builds Sign in with Apple requests and turns their results into `AppleCredential`s.
enum AppleSignIn {
    /// A fresh random nonce. Apple puts its SHA-256 in the ID token, which ties the token to this
    /// request so it can't be replayed.
    static func makeNonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func configure(_ request: ASAuthorizationAppleIDRequest, nonce: String) {
        // No email: the app never needs it.
        request.requestedScopes = [.fullName]
        request.nonce = sha256(nonce)
    }

    static func credential(from authorization: ASAuthorization, nonce: String) throws -> AppleCredential {
        guard let appleID = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = appleID.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            throw AppleSignInError.missingIdentityToken
        }
        return AppleCredential(
            idToken: idToken,
            rawNonce: nonce,
            authorizationCode: appleID.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            fullName: appleID.fullName
        )
    }

    /// The user closed the Apple sheet. Not worth an error message.
    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }
}

enum AppleSignInError: LocalizedError {
    case missingIdentityToken
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: String(localized: "Apple didn't return an identity token.")
        case .alreadyInProgress: String(localized: "Sign in with Apple is already in progress.")
        }
    }
}

/// Asks for a fresh Sign in with Apple without a button, to confirm deleting the account.
/// Throws `CancellationError` if the user closes the sheet.
@MainActor
protocol AppleReauthenticator {
    func requestCredential() async throws -> AppleCredential
}

@MainActor
final class SystemAppleReauthenticator: NSObject, AppleReauthenticator {
    private var pending: (controller: ASAuthorizationController, nonce: String, continuation: CheckedContinuation<AppleCredential, Error>)?

    func requestCredential() async throws -> AppleCredential {
        guard pending == nil else { throw AppleSignInError.alreadyInProgress }
        let nonce = AppleSignIn.makeNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        AppleSignIn.configure(request, nonce: nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            pending = (controller, nonce, continuation)
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        guard let pending else { return }
        self.pending = nil
        switch result {
        case .success(let authorization):
            pending.continuation.resume(with: Result { try AppleSignIn.credential(from: authorization, nonce: pending.nonce) })
        case .failure(let error) where AppleSignIn.isCancellation(error):
            pending.continuation.resume(throwing: CancellationError())
        case .failure(let error):
            pending.continuation.resume(throwing: error)
        }
    }
}

extension SystemAppleReauthenticator: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }
}

extension SystemAppleReauthenticator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}
