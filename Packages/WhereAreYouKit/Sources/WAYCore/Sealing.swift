//
//  Sealing.swift
//  WAYCore
//
//  End-to-end encryption between two identity keys, using HPKE (RFC 9180) in auth mode:
//  only the recipient can open a box, and opening proves the holder of the sender's key made it.
//

import CryptoKit
import Foundation

public enum CryptoError: Error, Equatable {
    case unsupportedVersion(Int)
    /// The box was made by or for a different key than the one supplied, e.g. after someone
    /// reinstalled without iCloud Keychain and generated a new key.
    case keyMismatch
    /// Wrong keys, wrong context, or tampered data. Deliberately says nothing more.
    case authenticationFailed
    /// Decrypted, but the content isn't a payload of the expected type.
    case malformedPayload
    /// A field is out of range. The associated value names the field.
    case invalidPayload(String)
    case invalidPublicKey
}

/// An encrypted payload, as stored in Firestore.
public struct SealedBox: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var senderKeyId: String
    public var recipientKeyId: String
    /// HPKE encapsulated key: the sender's ephemeral public key.
    public var encapsulatedKey: Data
    public var ciphertext: Data

    public init(version: Int, senderKeyId: String, recipientKeyId: String, encapsulatedKey: Data, ciphertext: Data) {
        self.version = version
        self.senderKeyId = senderKeyId
        self.recipientKeyId = recipientKeyId
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }
}

public enum Sealing {
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// Plaintexts are padded to a multiple of this, so ciphertext size doesn't reveal e.g. name length.
    static let paddingBlockSize = 64

    /// Encrypts `payload` so only `recipient` can read it. Seal to your own identity to back up
    /// data for your other devices.
    public static func seal<Payload: SealablePayload>(
        _ payload: Payload,
        from sender: IdentityKey,
        senderUid: String,
        to recipient: PublicIdentity,
        recipientUid: String
    ) throws -> SealedBox {
        try payload.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try seal(
            plaintext: encoder.encode(payload),
            kind: Payload.kind,
            from: sender,
            senderUid: senderUid,
            to: recipient,
            recipientUid: recipientUid
        )
    }

    /// Decrypts and validates a box made by `sender` for `recipient`.
    public static func open<Payload: SealablePayload>(
        _ type: Payload.Type,
        from box: SealedBox,
        sender: PublicIdentity,
        senderUid: String,
        recipient: IdentityKey,
        recipientUid: String
    ) throws -> Payload {
        guard box.version == SealedBox.currentVersion else {
            throw CryptoError.unsupportedVersion(box.version)
        }
        guard box.senderKeyId == sender.keyId, box.recipientKeyId == recipient.publicIdentity.keyId else {
            throw CryptoError.keyMismatch
        }
        let context = Context(
            kind: Payload.kind,
            senderUid: senderUid,
            recipientUid: recipientUid,
            senderKeyId: sender.keyId,
            recipientKeyId: recipient.publicIdentity.keyId
        )

        let padded: Data
        do {
            var hpke = try HPKE.Recipient(
                privateKey: recipient.privateKey,
                ciphersuite: ciphersuite,
                info: context.info,
                encapsulatedKey: box.encapsulatedKey,
                authenticatedBy: sender.publicKey
            )
            padded = try hpke.open(box.ciphertext, authenticating: context.associatedData)
        } catch {
            throw CryptoError.authenticationFailed
        }

        let payload: Payload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            payload = try decoder.decode(Payload.self, from: Padding.unpad(padded))
        } catch {
            throw CryptoError.malformedPayload
        }
        try payload.validate()
        return payload
    }

    /// Seals raw bytes. Internal so tests can produce boxes with content `seal` would refuse.
    static func seal(
        plaintext: Data,
        kind: PayloadKind,
        from sender: IdentityKey,
        senderUid: String,
        to recipient: PublicIdentity,
        recipientUid: String
    ) throws -> SealedBox {
        let context = Context(
            kind: kind,
            senderUid: senderUid,
            recipientUid: recipientUid,
            senderKeyId: sender.publicIdentity.keyId,
            recipientKeyId: recipient.keyId
        )
        var hpke = try HPKE.Sender(
            recipientKey: recipient.publicKey,
            ciphersuite: ciphersuite,
            info: context.info,
            authenticatedBy: sender.privateKey
        )
        let ciphertext = try hpke.seal(
            Padding.pad(plaintext, blockSize: paddingBlockSize),
            authenticating: context.associatedData
        )
        return SealedBox(
            version: SealedBox.currentVersion,
            senderKeyId: context.senderKeyId,
            recipientKeyId: context.recipientKeyId,
            encapsulatedKey: hpke.encapsulatedKey,
            ciphertext: ciphertext
        )
    }

    /// What a box is bound to. Opening with any field different fails authentication.
    struct Context {
        let kind: PayloadKind
        let senderUid: String
        let recipientUid: String
        let senderKeyId: String
        let recipientKeyId: String

        /// HPKE `info`: separates payload kinds so one can't be opened as another.
        var info: Data {
            Data("WhereAreYou v\(SealedBox.currentVersion) \(kind.rawValue)".utf8)
        }

        /// Length-prefixed fields, so no two different contexts encode to the same bytes.
        var associatedData: Data {
            var data = Data()
            for field in [kind.rawValue, senderUid, recipientUid, senderKeyId, recipientKeyId] {
                let bytes = Data(field.utf8)
                withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
                data.append(bytes)
            }
            return data
        }
    }
}

/// A 4-byte big-endian length, the plaintext, then zeros up to a multiple of the block size.
enum Padding {
    static func pad(_ data: Data, blockSize: Int) -> Data {
        var padded = Data()
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { padded.append(contentsOf: $0) }
        padded.append(data)
        let remainder = padded.count % blockSize
        if remainder != 0 {
            padded.append(Data(count: blockSize - remainder))
        }
        return padded
    }

    static func unpad(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw CryptoError.malformedPayload }
        let length = bytes[0..<4].reduce(0) { Int($0) << 8 | Int($1) }
        guard length <= bytes.count - 4, bytes[(4 + length)...].allSatisfy({ $0 == 0 }) else {
            throw CryptoError.malformedPayload
        }
        return Data(bytes[4..<(4 + length)])
    }
}
