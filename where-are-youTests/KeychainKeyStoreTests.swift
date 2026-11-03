//
//  KeychainKeyStoreTests.swift
//  where-are-youTests
//
//  Runs in the hosted app on the simulator: `swift test` on macOS has no Keychain entitlements.
//

import Foundation
import Testing
import WAYCore

@Suite(.serialized)
struct KeychainKeyStoreTests {
    /// A unique service per test, so runs never see each other's items.
    private func makeStore(synchronizable: Bool) -> KeychainKeyStore {
        KeychainKeyStore(service: "WhereAreYou.Tests.\(UUID().uuidString)", synchronizable: synchronizable)
    }

    @Test(arguments: [false, true])
    func savesLoadsAndDeletes(synchronizable: Bool) throws {
        let store = makeStore(synchronizable: synchronizable)
        defer { try? store.deleteIdentityKey(for: "alice") }

        #expect(try store.identityKey(for: "alice") == nil)

        let created = try store.loadOrCreateIdentityKey(for: "alice")
        #expect(created.isNew)
        #expect(try store.identityKey(for: "alice")?.publicIdentity == created.key.publicIdentity)

        try store.deleteIdentityKey(for: "alice")
        #expect(try store.identityKey(for: "alice") == nil)
    }

    @Test func savingAgainReplacesTheKey() throws {
        let store = makeStore(synchronizable: true)
        defer { try? store.deleteIdentityKey(for: "alice") }

        try store.save(IdentityKey.generate(), for: "alice")
        let replacement = IdentityKey.generate()
        try store.save(replacement, for: "alice")

        #expect(try store.identityKey(for: "alice")?.publicIdentity == replacement.publicIdentity)
    }

    @Test func accountsAreSeparate() throws {
        let store = makeStore(synchronizable: true)
        defer {
            try? store.deleteIdentityKey(for: "alice")
            try? store.deleteIdentityKey(for: "bob")
        }

        let alice = try store.loadOrCreateIdentityKey(for: "alice").key
        let bob = try store.loadOrCreateIdentityKey(for: "bob").key

        #expect(alice.publicIdentity != bob.publicIdentity)
        try store.deleteIdentityKey(for: "bob")
        #expect(try store.identityKey(for: "alice")?.publicIdentity == alice.publicIdentity)
    }

    @Test func deletingMissingKeyIsNotAnError() throws {
        try makeStore(synchronizable: true).deleteIdentityKey(for: "nobody")
    }
}
