//
//  SessionModelTests.swift
//  where-are-youTests
//

import Foundation
import Testing
import WAYCore
@testable import where_are_you

@MainActor
struct SessionModelTests {
    private struct Offline: Error {}

    private let uid = FakeBackend.testUID

    /// Starts `run()` and waits for setup to settle. The task stays alive for the test.
    private func start(_ session: SessionModel) async -> Task<Void, Never> {
        let task = Task { await session.run() }
        _ = await eventually { session.phase != .loading && session.phase != .settingUp }
        return task
    }

    private func profile(_ name: String = "Robin") -> Profile {
        Profile(displayName: name, avatar: Avatar(emoji: "🎸", color: .green))
    }

    // MARK: Setup

    @Test func signedOutUserSeesSignIn() async {
        let backend = FakeBackend(scenario: "signedOut")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .signedOut)
        #expect(session.account == nil)
    }

    @Test func newAccountCreatesAndPublishesKeyThenAsksForProfile() async throws {
        let backend = FakeBackend(scenario: "newUser")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .needsProfile)
        let stored = try #require(try backend.keyStore.identityKey(for: uid))
        #expect(await backend.account.identities[uid] == stored.publicIdentity)
    }

    @Test func returningUserIsReadyWithDecryptedProfile() async {
        let backend = FakeBackend(scenario: "ready")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .ready)
        #expect(session.account?.profile.displayName == "Test User")
        #expect(session.account?.uid == uid)
    }

    @Test func newDeviceWithoutSyncedKeyWaitsInsteadOfReplacingIt() async throws {
        let backend = FakeBackend(scenario: "newUser")
        let otherDevicesKey = IdentityKey.generate().publicIdentity
        await backend.account.setIdentity(otherDevicesKey, for: uid)
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .keyMissing)
        #expect(try backend.keyStore.identityKey(for: uid) == nil, "Must not generate a key on its own")
        #expect(await backend.account.identities[uid] == otherDevicesKey, "Must not replace the published key")
    }

    @Test func localKeyThatDiffersFromPublishedOneWaits() async {
        let backend = FakeBackend(scenario: "ready")
        await backend.account.setIdentity(IdentityKey.generate().publicIdentity, for: uid)
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .keyMissing)
    }

    @Test func savedButUnpublishedKeyGetsPublished() async throws {
        let backend = FakeBackend(scenario: "newUser")
        let key = IdentityKey.generate()
        try backend.keyStore.save(key, for: uid)
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(await backend.account.identities[uid] == key.publicIdentity)
        #expect(session.phase == .needsProfile)
    }

    @Test func profileSealedToAnOldKeyAsksForProfileAgain() async throws {
        let backend = FakeBackend(scenario: "ready")
        let oldKey = IdentityKey.generate()
        let staleBox = try Sealing.seal(profile(), from: oldKey, senderUid: uid, to: oldKey.publicIdentity, recipientUid: uid)
        await backend.account.setProfileBox(staleBox, for: uid)
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        #expect(session.phase == .needsProfile)
    }

    @Test func networkFailureCanBeRetried() async {
        let backend = FakeBackend(scenario: "ready")
        await backend.account.setFailure(Offline())
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }
        guard case .failed = session.phase else {
            Issue.record("Expected .failed, got \(session.phase)")
            return
        }

        await backend.account.setFailure(nil)
        session.retry()

        #expect(await eventually { session.phase == .ready })
    }

    // MARK: Profile and keys

    @Test func savingProfileSealsItToOwnKey() async throws {
        let backend = FakeBackend(scenario: "newUser")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        let saved = await session.saveProfile(profile())

        #expect(saved)
        #expect(session.phase == .ready)
        #expect(session.account?.profile == profile())
        let key = try #require(try backend.keyStore.identityKey(for: uid))
        let box = try #require(await backend.account.profileBoxes[uid])
        let opened = try Sealing.open(Profile.self, from: box, sender: key.publicIdentity, senderUid: uid, recipient: key, recipientUid: uid)
        #expect(opened == profile())
    }

    @Test func failedProfileSaveReportsErrorAndStays() async {
        let backend = FakeBackend(scenario: "newUser")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }
        await backend.account.setFailure(Offline())

        let saved = await session.saveProfile(profile())

        #expect(!saved)
        #expect(session.phase == .needsProfile)
        #expect(session.actionError != nil)
        #expect(!session.isWorking)
    }

    @Test func resetKeyPublishesNewKeyAndAsksForProfile() async throws {
        let backend = FakeBackend(scenario: "newUser")
        let otherDevicesKey = IdentityKey.generate().publicIdentity
        await backend.account.setIdentity(otherDevicesKey, for: uid)
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        await session.resetKey()

        #expect(session.phase == .needsProfile)
        let newKey = try #require(try backend.keyStore.identityKey(for: uid))
        #expect(newKey.publicIdentity != otherDevicesKey)
        #expect(await backend.account.identities[uid] == newKey.publicIdentity)
    }

    // MARK: Sign in and out

    @Test func signInSuggestsAppleName() async {
        let backend = FakeBackend(scenario: "signedOut")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }
        var name = PersonNameComponents()
        name.givenName = "Robin"
        name.familyName = "Diaz"

        await session.signIn(with: AppleCredential(idToken: "token", rawNonce: "nonce", authorizationCode: nil, fullName: name))

        #expect(await eventually { session.phase == .needsProfile })
        #expect(session.suggestedName == "Robin Diaz")
    }

    @Test func failedSignInShowsErrorAndStaysSignedOut() async {
        let backend = FakeBackend(scenario: "signedOut")
        backend.auth.failSignIn(with: Offline())
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        await session.signIn(with: AppleCredential(idToken: "token", rawNonce: "nonce", authorizationCode: nil, fullName: nil))

        #expect(session.phase == .signedOut)
        #expect(session.actionError != nil)
    }

    @Test func signOutClearsSessionButKeepsKey() async throws {
        let backend = FakeBackend(scenario: "ready")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        await session.signOut()

        #expect(await eventually { session.phase == .signedOut })
        #expect(session.account == nil)
        #expect(try backend.keyStore.identityKey(for: uid) != nil)
    }

    // MARK: Account deletion

    @Test func deleteAccountReauthenticatesRevokesDeletesAndCleansUp() async throws {
        let backend = FakeBackend(scenario: "ready")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        await session.deleteAccount()

        #expect(backend.auth.reauthenticationCount == 1)
        #expect(backend.auth.revokedCodes == ["authorization-code"])
        #expect(await backend.account.deletedAccounts == [uid])
        #expect(try backend.keyStore.identityKey(for: uid) == nil)
        #expect(session.phase == .signedOut)
        #expect(session.actionError == nil)
    }

    @Test func cancellingAppleConfirmationDeletesNothing() async throws {
        let backend = FakeBackend(scenario: "ready")
        backend.reauthenticator.cancels = true
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }

        await session.deleteAccount()

        #expect(await backend.account.deletedAccounts.isEmpty)
        #expect(backend.auth.revokedCodes.isEmpty)
        #expect(try backend.keyStore.identityKey(for: uid) != nil)
        #expect(session.phase == .ready)
        #expect(session.actionError == nil, "Cancelling isn't an error")
    }

    @Test func failedDeletionKeepsEverythingLocal() async throws {
        let backend = FakeBackend(scenario: "ready")
        let session = backend.makeSession()
        let task = await start(session)
        defer { task.cancel() }
        await backend.account.setFailure(Offline())

        await session.deleteAccount()

        #expect(session.actionError != nil)
        #expect(session.phase == .ready)
        #expect(try backend.keyStore.identityKey(for: uid) != nil)
    }

    @Test func emulatorDeletionSkipsApple() async {
        let backend = FakeBackend(scenario: "ready")
        let session = backend.makeSession(isUsingEmulator: true)
        let task = await start(session)
        defer { task.cancel() }

        await session.deleteAccount()

        #expect(backend.reauthenticator.requestCount == 0)
        #expect(await backend.account.deletedAccounts == [uid])
        #expect(session.phase == .signedOut)
    }

    @Test func everyOfferedEmojiIsAValidAvatar() throws {
        for emoji in ProfileEditorView.emojiChoices {
            try Profile(displayName: "Robin", avatar: Avatar(emoji: emoji, color: .blue)).validate()
        }
    }
}
