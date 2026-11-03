//
//  KeyTests.swift
//  WAYCoreTests
//

import CryptoKit
import Foundation
import Testing
@testable import WAYCore

struct IdentityKeyTests {
    @Test func keyIdIsShortStableAndUnique() throws {
        let key = IdentityKey.generate()
        let republished = try PublicIdentity(rawRepresentation: key.publicIdentity.rawRepresentation)

        #expect(key.publicIdentity.keyId.count == PublicIdentity.keyIdLength)
        #expect(republished.keyId == key.publicIdentity.keyId)
        #expect(republished == key.publicIdentity)
        #expect(IdentityKey.generate().publicIdentity.keyId != key.publicIdentity.keyId)
    }

    @Test func privateKeyRoundTripsThroughRawBytes() throws {
        let key = IdentityKey.generate()
        let restored = try IdentityKey(rawRepresentation: key.privateKey.rawRepresentation)
        #expect(restored.publicIdentity == key.publicIdentity)
    }

    @Test(arguments: [0, 31, 33])
    func rejectsWrongSizePublicKey(size: Int) {
        #expect(throws: CryptoError.invalidPublicKey) {
            try PublicIdentity(rawRepresentation: Data(count: size))
        }
    }
}

struct InMemoryKeyStoreTests {
    @Test func createsOnceThenReturnsSameKey() throws {
        let store = InMemoryKeyStore()

        let first = try store.loadOrCreateIdentityKey(for: "alice")
        let second = try store.loadOrCreateIdentityKey(for: "alice")

        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(second.key.publicIdentity == first.key.publicIdentity)
    }

    @Test func keysAreScopedPerAccount() throws {
        let store = InMemoryKeyStore()

        let alice = try store.loadOrCreateIdentityKey(for: "alice").key
        let bob = try store.loadOrCreateIdentityKey(for: "bob").key

        #expect(alice.publicIdentity != bob.publicIdentity)
    }

    @Test func deleteRemovesKeyAndIsIdempotent() throws {
        let store = InMemoryKeyStore()
        _ = try store.loadOrCreateIdentityKey(for: "alice")

        try store.deleteIdentityKey(for: "alice")
        try store.deleteIdentityKey(for: "alice")

        #expect(try store.identityKey(for: "alice") == nil)
    }
}

struct SecurityCodeTests {
    let alice = IdentityKey.generate().publicIdentity
    let bob = IdentityKey.generate().publicIdentity

    @Test func sameOnBothDevices() {
        #expect(SecurityCode.digits(alice, bob) == SecurityCode.digits(bob, alice))
    }

    @Test func twelveGroupsOfFiveDigits() {
        let groups = SecurityCode.digits(alice, bob).split(separator: " ")
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
    }

    @Test func changesWhenEitherKeyChanges() {
        let carol = IdentityKey.generate().publicIdentity
        #expect(SecurityCode.digits(alice, bob) != SecurityCode.digits(alice, carol))
        #expect(SecurityCode.digits(alice, bob) != SecurityCode.digits(carol, bob))
    }
}

struct Base64URLTests {
    @Test func roundTripsWithoutPaddingOrUnsafeCharacters() throws {
        for length in 0...40 {
            let data = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            let encoded = data.base64URLEncodedString()
            #expect(!encoded.contains { "+/=".contains($0) })
            #expect(Data(base64URLEncoded: encoded) == data)
        }
    }

    @Test(arguments: ["abc+", "abc/", "ab=c", "a b", "é", "A"])
    func rejectsInvalidInput(input: String) {
        #expect(Data(base64URLEncoded: input) == nil)
    }
}
