//
//  LiveFriendsRepositoryTests.swift
//  where-are-youTests
//

import Foundation
import Testing
import WAYCore
@testable import where_are_you

@MainActor
struct LiveFriendsRepositoryTests {
    private let me = Account(uid: "me", identity: .generate(), profile: Profile(displayName: "Me", avatar: Avatar(emoji: nil, color: .red)))
    private let oliviaKey = IdentityKey.generate()
    private let oliviaProfile = Profile(displayName: "Olivia", avatar: Avatar(emoji: "🎸", color: .green))

    private let backend = FakeFriendsBackend()
    private let auth = FakeAuthBackend(signedInAs: "me")
    private let pins = InMemoryPinnedKeyStore()
    private let directory = InMemoryFriendDirectoryStore()

    private func makeAccounts() async -> FakeAccountBackend {
        let accounts = FakeAccountBackend(auth: auth)
        await accounts.setIdentity(oliviaKey.publicIdentity, for: "olivia")
        return accounts
    }

    private func oliviasShare(sealedWith key: IdentityKey? = nil) throws -> ShareDocument {
        let key = key ?? oliviaKey
        return ShareDocument(
            senderUid: "olivia",
            profile: try Sealing.seal(oliviaProfile, from: key, senderUid: "olivia", to: me.identity.publicIdentity, recipientUid: "me"),
            location: nil,
            isSharingLocation: false
        )
    }

    /// Collects the latest emitted list while the test runs.
    private final class Latest {
        var friends: [Friend]?
    }

    /// Starts listening and waits until the repository's listeners are registered.
    private func observe(_ repository: LiveFriendsRepository) async -> (Latest, Task<Void, Never>) {
        let latest = Latest()
        let stream = repository.friends()
        let task = Task { @MainActor in
            do {
                for try await friends in stream {
                    latest.friends = friends
                }
            } catch {
                Issue.record("Friends stream failed: \(error)")
            }
        }
        _ = await eventually { backend.isListening }
        return (latest, task)
    }

    @Test func decryptsFriendsAndPinsTheirKeyOnFirstUse() async throws {
        let repository = LiveFriendsRepository(account: me, backend: backend, accounts: await makeAccounts(), pins: pins, directory: directory)
        let (latest, task) = await observe(repository)
        defer { task.cancel() }

        backend.sendFriends(["olivia"])
        backend.sendShares([try oliviasShare()])

        #expect(await eventually { latest.friends?.first?.displayName == "Olivia" })
        #expect(await eventually { (try? pins.pins(for: "me")["olivia"]) == PinnedKey(keyId: oliviaKey.publicIdentity.keyId, trust: .firstUse) })
        #expect(await eventually { latest.friends?.first?.keyStatus == .trusted(.firstUse) })
        // The notification extension's directory has her name and key.
        #expect(await eventually { (try? directory.directory(for: "me").entries["olivia"]) == FriendDirectory.Entry(displayName: "Olivia", publicKey: oliviaKey.publicIdentity.rawRepresentation) })
    }

    @Test func sharesOwnProfileWithNewFriends() async throws {
        let repository = LiveFriendsRepository(account: me, backend: backend, accounts: await makeAccounts(), pins: pins, directory: directory)
        let (_, task) = await observe(repository)
        defer { task.cancel() }

        backend.sendFriends(["olivia"])
        backend.sendShares([])

        #expect(await eventually { backend.publishedShares["olivia"]?["me"] != nil })
        let box = try #require(backend.publishedShares["olivia"]?["me"]?.profile)
        let profile = try Sealing.open(Profile.self, from: box, sender: me.identity.publicIdentity, senderUid: "me", recipient: oliviaKey, recipientUid: "olivia")
        #expect(profile == me.profile)
    }

    @Test func flagsAChangedKeyAndKeepsSharingWithTheNewOne() async throws {
        try pins.setPin(PinnedKey(keyId: oliviaKey.publicIdentity.keyId, trust: .invite), forFriend: "olivia", account: "me")
        let accounts = await makeAccounts()
        let newKey = IdentityKey.generate()
        await accounts.setIdentity(newKey.publicIdentity, for: "olivia")
        let repository = LiveFriendsRepository(account: me, backend: backend, accounts: accounts, pins: pins, directory: directory)
        let (latest, task) = await observe(repository)
        defer { task.cancel() }

        backend.sendFriends(["olivia"])
        backend.sendShares([try oliviasShare(sealedWith: newKey)])

        #expect(await eventually { latest.friends?.first?.keyStatus == .changed })
        #expect(await eventually { backend.publishedShares["olivia"]?["me"]?.profile.recipientKeyId == newKey.publicIdentity.keyId })

        try repository.acceptKeyChange("olivia")
        #expect(await eventually { latest.friends?.first?.keyStatus == .trusted(.firstUse) })
    }

    @Test func verifyingAndRemovingUpdatePins() async throws {
        let repository = LiveFriendsRepository(account: me, backend: backend, accounts: await makeAccounts(), pins: pins, directory: directory)
        let (latest, task) = await observe(repository)
        defer { task.cancel() }
        backend.sendFriends(["olivia"])
        backend.sendShares([try oliviasShare()])
        #expect(await eventually { latest.friends?.first?.identity != nil })

        try repository.markKeyVerified("olivia")
        #expect(try pins.pins(for: "me")["olivia"]?.trust == .compared)

        try await repository.removeFriend("olivia")
        #expect(backend.removedFriends == ["olivia"])
        #expect(try pins.pins(for: "me")["olivia"] == nil)
    }
}
