//
//  FriendsTests.swift
//  where-are-youTests
//

import Foundation
import Testing
import WAYCore
@testable import where_are_you

struct FriendFixtureTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func loadFixture() throws -> [Friend] {
        let url = try #require(Bundle.main.url(forResource: "friends", withExtension: "json"))
        return try FriendFixture.decode(Data(contentsOf: url), now: now)
    }

    @Test func decodesEveryFriend() throws {
        let friends = try loadFixture()

        #expect(friends.count == 8)
        let olivia = try #require(friends.first { $0.id == "QW345DVJjdfe" })
        #expect(olivia.displayName == "Olivia Bennett")
        #expect(olivia.avatar == Avatar(emoji: nil, color: .orange))
        #expect(olivia.location?.timestamp == now.addingTimeInterval(-5 * 60))
    }

    @Test func friendWithoutLocationDecodesAsNil() throws {
        let brett = try #require(try loadFixture().first { $0.displayName == "Brett Cooper" })
        #expect(brett.location == nil)
    }

    // Regression: Noah used to sit at latitude 85.69, beyond what MapKit can draw.
    @Test func everyLocationIsDrawableOnTheMap() throws {
        for friend in try loadFixture() {
            guard let location = friend.location else { continue }
            #expect(abs(location.latitude) <= 85.05, "\(friend.displayName) is outside MapKit's range")
            #expect(abs(location.longitude) <= 180)
        }
    }

    @Test func fixtureFriendsHaveStableKeysAndOneChangedKey() throws {
        let friends = try loadFixture()
        let again = try loadFixture()

        #expect(friends.allSatisfy { $0.identity != nil })
        #expect(friends.map(\.identity) == again.map(\.identity))
        #expect(friends.first { $0.displayName == "Ethan Carter" }?.keyStatus == .changed)
    }

    // Regression: Liam and Sophia used to share coordinates, so one pin hid the other.
    @Test func noTwoFriendsShareCoordinates() throws {
        let coordinates = try loadFixture().compactMap { friend in
            friend.location.map { "\($0.latitude),\($0.longitude)" }
        }
        #expect(Set(coordinates).count == coordinates.count)
    }

    @Test func rejectsMalformedData() {
        #expect(throws: DecodingError.self) {
            try FriendFixture.decode(Data(#"{"friends": [{"id": 1}]}"#.utf8), now: now)
        }
    }
}

@MainActor
struct FriendsStoreTests {
    @MainActor
    private final class FailingRepository: FriendsRepository {
        struct Failure: Error {}

        func friends() -> AsyncThrowingStream<[Friend], Error> {
            AsyncThrowingStream { $0.finish(throwing: Failure()) }
        }

        func createInvite() async throws -> InviteLink { throw Failure() }
        func acceptInvite(_ link: InviteLink) async throws { throw Failure() }
        func removeFriend(_ id: Friend.ID) async throws { throw Failure() }
        func markKeyVerified(_ id: Friend.ID) throws { throw Failure() }
        func acceptKeyChange(_ id: Friend.ID) throws { throw Failure() }
        func shareProfile(_ profile: Profile) async {}
    }

    private func friend(_ name: String) -> Friend {
        Friend(id: name, displayName: name, avatar: Avatar(emoji: nil, color: .blue), location: nil)
    }

    /// The fixture stream stays open for later edits, so observe in the background.
    private func observe(_ store: FriendsStore) async -> Task<Void, Never> {
        let task = Task { await store.observe() }
        _ = await eventually { store.loadState != .loading }
        return task
    }

    @Test func sortsFriendsByName() async {
        let store = FriendsStore(repository: FixtureFriendsRepository(friends: [friend("zoë"), friend("Adam"), friend("émile")]))
        let task = await observe(store)
        defer { task.cancel() }

        #expect(store.friends.map(\.displayName) == ["Adam", "émile", "zoë"])
        #expect(store.loadState == .loaded)
    }

    @Test func emptySourceIsLoaded() async {
        let store = FriendsStore(repository: FixtureFriendsRepository(friends: []))
        let task = await observe(store)
        defer { task.cancel() }

        #expect(store.friends.isEmpty)
        #expect(store.loadState == .loaded)
    }

    @Test func failureIsReportedAndRetryChangesToken() async {
        let store = FriendsStore(repository: FailingRepository())

        await store.observe()
        #expect(store.loadState == .failed)

        let token = store.reloadToken
        store.retry()
        #expect(store.reloadToken != token)
    }

    @Test func findsFriendByID() async {
        let store = FriendsStore(repository: FixtureFriendsRepository(friends: [friend("Adam")]))
        let task = await observe(store)
        defer { task.cancel() }

        #expect(store.friend(id: "Adam")?.displayName == "Adam")
        #expect(store.friend(id: "missing") == nil)
    }

    @Test func actionsUpdateTheList() async throws {
        let store = FriendsStore(repository: FixtureFriendsRepository(friends: [friend("Adam"), friend("Bea")]))
        let task = await observe(store)
        defer { task.cancel() }

        try await store.removeFriend("Adam")
        #expect(await eventually { store.friends.map(\.id) == ["Bea"] })

        try store.markKeyVerified("Bea")
        #expect(await eventually { store.friend(id: "Bea")?.keyStatus == .trusted(.compared) })

        let invite = try await store.createInvite()
        try await store.acceptInvite(invite)
        #expect(await eventually { store.friends.count == 2 })
    }
}
