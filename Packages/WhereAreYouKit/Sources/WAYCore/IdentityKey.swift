//
//  IdentityKey.swift
//  WAYCore
//

import CryptoKit
import Foundation

/// The public half of someone's identity key, as published in their `users/{uid}` document.
public struct PublicIdentity: Hashable, Sendable {
    /// Length of a key ID string: 16 bytes of SHA-256, base64url-encoded.
    public static let keyIdLength = 22

    public let publicKey: Curve25519.KeyAgreement.PublicKey
    /// Short, stable identifier for this key. Changes whenever the key does.
    public let keyId: String

    public var rawRepresentation: Data {
        publicKey.rawRepresentation
    }

    public init(rawRepresentation: Data) throws {
        do {
            self.init(publicKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation))
        } catch {
            throw CryptoError.invalidPublicKey
        }
    }

    init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        self.publicKey = publicKey
        keyId = Data(SHA256.hash(data: publicKey.rawRepresentation).prefix(16)).base64URLEncodedString()
    }

    public static func == (lhs: PublicIdentity, rhs: PublicIdentity) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawRepresentation)
    }
}

/// The current user's identity key pair. The private key never leaves the Keychain except to
/// sync through iCloud Keychain.
public struct IdentityKey: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicIdentity: PublicIdentity

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        publicIdentity = PublicIdentity(publicKey: privateKey.publicKey)
    }

    public init(rawRepresentation: Data) throws {
        self.init(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation))
    }

    public static func generate() -> IdentityKey {
        IdentityKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }
}
