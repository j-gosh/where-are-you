//
//  SealingTests.swift
//  WAYCoreTests
//

import CryptoKit
import Foundation
import Testing
@testable import WAYCore

struct SealingTests {
    let alice = IdentityKey.generate()
    let bob = IdentityKey.generate()
    let mallory = IdentityKey.generate()

    let location = SharedLocation(
        latitude: 48.8566,
        longitude: 2.3522,
        horizontalAccuracy: 12,
        isApproximate: false,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000)
    )

    private func sealLocation(from sender: IdentityKey = IdentityKey.generate(), senderUid: String = "alice") throws -> SealedBox {
        try Sealing.seal(location, from: sender, senderUid: senderUid, to: bob.publicIdentity, recipientUid: "bob")
    }

    private func openLocation(
        _ box: SealedBox,
        sender: PublicIdentity,
        senderUid: String = "alice",
        recipient: IdentityKey? = nil,
        recipientUid: String = "bob"
    ) throws -> SharedLocation {
        try Sealing.open(SharedLocation.self, from: box, sender: sender, senderUid: senderUid, recipient: recipient ?? bob, recipientUid: recipientUid)
    }

    // MARK: Round trips

    @Test func locationRoundTrips() throws {
        let box = try sealLocation(from: alice)
        #expect(try openLocation(box, sender: alice.publicIdentity) == location)
        #expect(box.version == SealedBox.currentVersion)
        #expect(box.senderKeyId == alice.publicIdentity.keyId)
        #expect(box.recipientKeyId == bob.publicIdentity.keyId)
    }

    @Test func everyPayloadKindRoundTrips() throws {
        let profile = Profile(displayName: "Zoë Ångström", avatar: Avatar(emoji: "🎸", color: .green))
        let request = AlertRequest(id: "alert-1", placeName: "Home", latitude: 1, longitude: 2, radius: 150, trigger: .arrive)
        let event = AlertEvent(alertId: "alert-1", placeName: "Home", trigger: .leave, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))

        func roundTrip<P: SealablePayload & Equatable>(_ payload: P) throws {
            let box = try Sealing.seal(payload, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob")
            let opened = try Sealing.open(P.self, from: box, sender: alice.publicIdentity, senderUid: "alice", recipient: bob, recipientUid: "bob")
            #expect(opened == payload)
        }
        try roundTrip(profile)
        try roundTrip(request)
        try roundTrip(event)
    }

    @Test func canSealToSelf() throws {
        let profile = Profile(displayName: "Alice", avatar: Avatar(emoji: nil, color: .red))
        let box = try Sealing.seal(profile, from: alice, senderUid: "alice", to: alice.publicIdentity, recipientUid: "alice")
        let opened = try Sealing.open(Profile.self, from: box, sender: alice.publicIdentity, senderUid: "alice", recipient: alice, recipientUid: "alice")
        #expect(opened == profile)
    }

    @Test func sealingTwiceGivesDifferentCiphertexts() throws {
        #expect(try sealLocation(from: alice).ciphertext != sealLocation(from: alice).ciphertext)
    }

    @Test func survivesCodableRoundTripLikeFirestore() throws {
        let box = try sealLocation(from: alice)
        let stored = try JSONDecoder().decode(SealedBox.self, from: JSONEncoder().encode(box))
        #expect(try openLocation(stored, sender: alice.publicIdentity) == location)
    }

    // MARK: Who can open it

    @Test func otherRecipientCannotOpen() throws {
        let box = try sealLocation(from: alice)
        #expect(throws: CryptoError.keyMismatch) {
            try openLocation(box, sender: alice.publicIdentity, recipient: mallory)
        }
    }

    @Test func otherRecipientCannotOpenEvenWithForgedKeyId() throws {
        var box = try sealLocation(from: alice)
        box.recipientKeyId = mallory.publicIdentity.keyId
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity, recipient: mallory)
        }
    }

    /// The server knows Bob's public key, so it could encrypt anything to him. Auth mode means it
    /// still can't pass that off as coming from Alice.
    @Test func cannotForgeSender() throws {
        var box = try sealLocation(from: mallory)
        box.senderKeyId = alice.publicIdentity.keyId
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func boxFromReplacedKeyReportsKeyMismatch() throws {
        let box = try sealLocation(from: alice)
        let alicesNewKey = IdentityKey.generate()
        #expect(throws: CryptoError.keyMismatch) {
            try openLocation(box, sender: alicesNewKey.publicIdentity)
        }
    }

    // MARK: Context binding

    @Test(arguments: [
        ("mallory", "bob"),
        ("alice", "carol"),
    ])
    func boxCannotMoveToAnotherDocument(senderUid: String, recipientUid: String) throws {
        let box = try sealLocation(from: alice)
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity, senderUid: senderUid, recipientUid: recipientUid)
        }
    }

    @Test func boxCannotBeOpenedAsAnotherKind() throws {
        let profile = Profile(displayName: "Alice", avatar: Avatar(emoji: nil, color: .red))
        let box = try Sealing.seal(profile, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob")
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    // MARK: Tampering

    @Test func tamperedCiphertextFails() throws {
        var box = try sealLocation(from: alice)
        box.ciphertext[box.ciphertext.startIndex] ^= 0x01
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func tamperedEncapsulatedKeyFails() throws {
        var box = try sealLocation(from: alice)
        box.encapsulatedKey[box.encapsulatedKey.startIndex] ^= 0x01
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func truncatedCiphertextFails() throws {
        var box = try sealLocation(from: alice)
        box.ciphertext = box.ciphertext.prefix(10)
        #expect(throws: CryptoError.authenticationFailed) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func unknownVersionIsRejected() throws {
        var box = try sealLocation(from: alice)
        box.version = 2
        #expect(throws: CryptoError.unsupportedVersion(2)) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    // MARK: Content checks

    @Test func refusesToSealInvalidPayload() {
        var bad = location
        bad.latitude = 91
        #expect(throws: CryptoError.invalidPayload("coordinate")) {
            try Sealing.seal(bad, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob")
        }
    }

    /// Another client could send out-of-range data; the receiver validates too.
    @Test func rejectsInvalidPayloadOnOpen() throws {
        let json = #"{"latitude":200,"longitude":0,"horizontalAccuracy":5,"isApproximate":false,"timestamp":0}"#
        let box = try Sealing.seal(plaintext: Data(json.utf8), kind: .location, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob")
        #expect(throws: CryptoError.invalidPayload("coordinate")) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func rejectsGarbagePlaintext() throws {
        let box = try Sealing.seal(plaintext: Data("not json".utf8), kind: .location, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob")
        #expect(throws: CryptoError.malformedPayload) {
            try openLocation(box, sender: alice.publicIdentity)
        }
    }

    @Test func paddingHidesNameLength() throws {
        func ciphertextSize(for name: String) throws -> Int {
            let profile = Profile(displayName: name, avatar: Avatar(emoji: nil, color: .red))
            return try Sealing.seal(profile, from: alice, senderUid: "alice", to: bob.publicIdentity, recipientUid: "bob").ciphertext.count
        }
        #expect(try ciphertextSize(for: "Al") == ciphertextSize(for: "Alexandria Ocasio"))
    }

    @Test func sealingToLowOrderKeyFails() throws {
        let zeroKey = try PublicIdentity(rawRepresentation: Data(count: 32))
        #expect(throws: (any Error).self) {
            try Sealing.seal(location, from: alice, senderUid: "alice", to: zeroKey, recipientUid: "bob")
        }
    }
}

struct PaddingTests {
    @Test(arguments: [0, 1, 59, 60, 61, 200])
    func padsToBlockMultipleAndRoundTrips(length: Int) throws {
        let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 + 1) })
        let padded = Padding.pad(data, blockSize: 64)
        #expect(padded.count % 64 == 0)
        #expect(try Padding.unpad(padded) == data)
    }

    @Test func rejectsLengthBeyondData() {
        #expect(throws: CryptoError.malformedPayload) {
            try Padding.unpad(Data([0, 0, 1, 0, 1, 2, 3]))
        }
    }

    @Test func rejectsNonZeroPadding() {
        var padded = Padding.pad(Data([1, 2, 3]), blockSize: 64)
        padded[padded.count - 1] = 7
        #expect(throws: CryptoError.malformedPayload) {
            try Padding.unpad(padded)
        }
    }

    @Test func rejectsTooShort() {
        #expect(throws: CryptoError.malformedPayload) {
            try Padding.unpad(Data([0, 0]))
        }
    }
}
