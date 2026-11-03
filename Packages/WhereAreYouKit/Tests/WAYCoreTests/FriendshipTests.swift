//
//  FriendshipTests.swift
//  WAYCoreTests
//

import Foundation
import Testing
@testable import WAYCore

struct InviteFlowTests {
    let backend = TestBackend(caller: "olivia")
    let pins = InMemoryPinnedKeyStore()

    var flow: InviteFlow {
        InviteFlow(friends: backend, accounts: backend, pins: pins)
    }

    @Test func createdInviteCarriesKeyIdAndNameAndExpiresInThreeDays() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let link = try await flow.createInvite(for: olivia, now: now)

        #expect(link.inviterKeyId == olivia.identity.publicIdentity.keyId)
        #expect(link.inviterName == "Olivia")
        let stored = try #require(await backend.invites[link.token])
        #expect(stored == InviteDocument(inviterUid: "olivia", inviterKeyId: link.inviterKeyId, expiresAt: now.addingTimeInterval(InviteFlow.lifetime)))
    }

    @Test func acceptingBecomesFriendsPinsKeyAndSharesProfile() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let ethan = await makeAccount("ethan", name: "Ethan", backend: backend)
        let link = try await flow.createInvite(for: olivia)
        await backend.setCaller("ethan")

        let friend = try await flow.accept(link, as: ethan)

        #expect(friend == "olivia")
        #expect(await backend.friendships.contains(["olivia", "ethan"]))
        #expect(await backend.invites[link.token] == nil)
        #expect(try pins.pins(for: "ethan")["olivia"] == PinnedKey(keyId: olivia.identity.publicIdentity.keyId, trust: .invite))
        // Olivia can read the profile Ethan shared with her.
        let share = try #require(await backend.shares["olivia"]?["ethan"])
        let profile = try Sealing.open(Profile.self, from: share.profile, sender: ethan.identity.publicIdentity, senderUid: "ethan", recipient: olivia.identity, recipientUid: "olivia")
        #expect(profile == ethan.profile)
        #expect(!share.isSharingLocation)
    }

    /// The server could publish its own key for Olivia; the key ID from Messages exposes that.
    @Test func swappedInviterKeyIsRejectedBeforeAccepting() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let ethan = await makeAccount("ethan", name: "Ethan", backend: backend)
        let link = try await flow.createInvite(for: olivia)
        await backend.setIdentity(IdentityKey.generate().publicIdentity, for: "olivia")
        await backend.setCaller("ethan")

        await #expect(throws: InviteError.keyMismatch) {
            try await flow.accept(link, as: ethan)
        }
        #expect(await backend.friendships.isEmpty)
        #expect(await backend.invites[link.token] != nil, "Nothing was accepted")
    }

    @Test func expiredOrMissingInvitesAreRejected() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let ethan = await makeAccount("ethan", name: "Ethan", backend: backend)
        let link = try await flow.createInvite(for: olivia, now: Date(timeIntervalSinceNow: -InviteFlow.lifetime - 60))
        await backend.setCaller("ethan")

        await #expect(throws: InviteError.expiredOrUsed) {
            try await flow.accept(link, as: ethan)
        }
        let unknown = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: olivia.identity.publicIdentity.keyId, inviterName: nil)
        await #expect(throws: InviteError.expiredOrUsed) {
            try await flow.accept(unknown, as: ethan)
        }
    }

    @Test func ownInviteIsRejected() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let link = try await flow.createInvite(for: olivia)

        await #expect(throws: InviteError.ownInvite) {
            try await flow.accept(link, as: olivia)
        }
    }

    @Test func inviterWithoutPublishedKeyIsReported() async throws {
        let olivia = await makeAccount("olivia", name: "Olivia", backend: backend)
        let ethan = await makeAccount("ethan", name: "Ethan", backend: backend)
        let link = try await flow.createInvite(for: olivia)
        await backend.setIdentity(nil, for: "olivia")

        await #expect(throws: InviteError.inviterNotSetUp) {
            try await flow.accept(link, as: ethan)
        }
    }
}

struct ProfileSharingTests {
    let box = SealedBox(version: 1, senderKeyId: "me", recipientKeyId: "friend", encapsulatedKey: Data(), ciphertext: Data())

    @Test func republishesWhenMissingOrSealedWithOldKeys() {
        let share = ShareDocument(senderUid: "me", profile: box, location: nil, isSharingLocation: false)

        #expect(ProfileSharing.needsRepublish(nil, myKeyId: "me", friendKeyId: "friend"))
        #expect(!ProfileSharing.needsRepublish(share, myKeyId: "me", friendKeyId: "friend"))
        #expect(ProfileSharing.needsRepublish(share, myKeyId: "my-new-key", friendKeyId: "friend"))
        #expect(ProfileSharing.needsRepublish(share, myKeyId: "me", friendKeyId: "their-new-key"))
    }
}

struct FriendAssemblerTests {
    let me = Account(uid: "me", identity: .generate(), profile: Profile(displayName: "Me", avatar: Avatar(emoji: nil, color: .red)))
    let friendKey = IdentityKey.generate()
    let friendProfile = Profile(displayName: "Olivia", avatar: Avatar(emoji: "🎸", color: .green))
    let location = SharedLocation(latitude: 1, longitude: 2, horizontalAccuracy: 5, isApproximate: false, timestamp: Date(timeIntervalSince1970: 1_800_000_000))

    private func share(sealedFor recipient: PublicIdentity? = nil, sharingLocation: Bool = true) throws -> ShareDocument {
        let recipient = recipient ?? me.identity.publicIdentity
        return ShareDocument(
            senderUid: "olivia",
            profile: try Sealing.seal(friendProfile, from: friendKey, senderUid: "olivia", to: recipient, recipientUid: "me"),
            location: try Sealing.seal(location, from: friendKey, senderUid: "olivia", to: recipient, recipientUid: "me"),
            isSharingLocation: sharingLocation
        )
    }

    private func assemble(
        shares: [String: ShareDocument] = [:],
        identities: [String: PublicIdentity]? = nil,
        pins: [String: PinnedKey] = [:]
    ) -> FriendRecord? {
        FriendAssembler.assemble(
            friendUIDs: ["olivia"],
            shares: shares,
            identities: identities ?? ["olivia": friendKey.publicIdentity],
            pins: pins,
            account: me
        ).first
    }

    @Test func decryptsProfileAndLocation() throws {
        let record = try #require(assemble(shares: ["olivia": share()]))

        #expect(record.profile == friendProfile)
        #expect(record.location == location)
        #expect(record.problem == nil)
        #expect(record.keyStatus == .trusted(.firstUse))
    }

    @Test func hidesLocationWhenNotSharing() throws {
        let record = try #require(assemble(shares: ["olivia": share(sharingLocation: false)]))

        #expect(record.profile == friendProfile)
        #expect(record.location == nil)
    }

    @Test func newFriendWithoutShareIsWaiting() throws {
        #expect(assemble()?.problem == .waitingForProfile)
    }

    @Test func missingKeyIsReported() throws {
        #expect(try assemble(shares: ["olivia": share()], identities: [:])?.problem == .keyUnavailable)
    }

    @Test func shareSealedForMyOldKeyWaitsForNewOne() throws {
        let oldKey = IdentityKey.generate().publicIdentity
        #expect(try assemble(shares: ["olivia": share(sealedFor: oldKey)])?.problem == .waitingForNewKey)
    }

    @Test func tamperedShareIsUnreadable() throws {
        var tampered = try share()
        tampered.profile.ciphertext[tampered.profile.ciphertext.startIndex] ^= 1
        #expect(assemble(shares: ["olivia": tampered])?.problem == .unreadable)
    }

    @Test func reportsPinnedTrustAndKeyChanges() throws {
        let keyId = friendKey.publicIdentity.keyId
        #expect(assemble(pins: ["olivia": PinnedKey(keyId: keyId, trust: .compared)])?.keyStatus == .trusted(.compared))
        #expect(assemble(pins: ["olivia": PinnedKey(keyId: "an-older-key-id", trust: .invite)])?.keyStatus == .changed)
        #expect(assemble(identities: [:])?.keyStatus == .unknown)
    }

    @Test func ignoresSharesFromNonFriends() throws {
        let records = FriendAssembler.assemble(
            friendUIDs: [],
            shares: ["olivia": try share()],
            identities: ["olivia": friendKey.publicIdentity],
            pins: [:],
            account: me
        )
        #expect(records.isEmpty)
    }
}

struct AccountLoaderTests {
    let backend = TestBackend(caller: "me")
    let keyStore = InMemoryKeyStore()

    private func setUpFully() async throws -> IdentityKey {
        let key = IdentityKey.generate()
        try keyStore.save(key, for: "me")
        try await backend.publishIdentity(key.publicIdentity, for: "me")
        let profile = Profile(displayName: "Me", avatar: Avatar(emoji: nil, color: .red))
        try await backend.saveOwnProfileBox(Sealing.seal(profile, from: key, senderUid: "me", to: key.publicIdentity, recipientUid: "me"), for: "me")
        return key
    }

    @Test func loadsFullySetUpAccount() async throws {
        let key = try await setUpFully()

        let account = try await AccountLoader.loadExisting(uid: "me", keyStore: keyStore, accounts: backend)

        #expect(account?.profile.displayName == "Me")
        #expect(account?.identity.publicIdentity == key.publicIdentity)
    }

    @Test func incompleteSetupLoadsNothing() async throws {
        #expect(try await AccountLoader.loadExisting(uid: "me", keyStore: keyStore, accounts: backend) == nil)

        _ = try await setUpFully()
        await backend.setIdentity(IdentityKey.generate().publicIdentity, for: "me")
        #expect(try await AccountLoader.loadExisting(uid: "me", keyStore: keyStore, accounts: backend) == nil)
    }
}

struct InMemoryPinnedKeyStoreTests {
    @Test func pinsAreScopedPerAccountAndRemovable() throws {
        let store = InMemoryPinnedKeyStore()
        let pin = PinnedKey(keyId: "key", trust: .invite)

        try store.setPin(pin, forFriend: "olivia", account: "me")
        #expect(try store.pins(for: "me") == ["olivia": pin])
        #expect(try store.pins(for: "someone-else").isEmpty)

        try store.setPin(nil, forFriend: "olivia", account: "me")
        #expect(try store.pins(for: "me").isEmpty)
    }
}
