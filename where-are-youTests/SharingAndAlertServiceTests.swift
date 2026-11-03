//
//  SharingAndAlertServiceTests.swift
//  where-are-youTests
//

import Foundation
import Testing
import WAYCore
@testable import where_are_you

private func isolatedDefaults() -> UserDefaults {
    let name = "tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
struct SharingServiceTests {
    private let me = Account(uid: "me", identity: .generate(), profile: Profile(displayName: "Me", avatar: Avatar(emoji: nil, color: .red)))
    private let oliviaKey = IdentityKey.generate()
    private let backend = InMemorySharingAndAlerts()
    private let friends = FakeFriendsBackend()
    private let auth = FakeAuthBackend(signedInAs: "me")
    private let background = NoBackgroundLocation()

    private let start = UserLocation(latitude: 48.8566, longitude: 2.3522, horizontalAccuracy: 10, timestamp: Date(timeIntervalSince1970: 1_800_000_000))

    private func location(metersNorth: Double, secondsLater: TimeInterval) -> UserLocation {
        UserLocation(latitude: start.latitude + metersNorth / 111_000, longitude: start.longitude, horizontalAccuracy: 10, timestamp: start.timestamp.addingTimeInterval(secondsLater))
    }

    /// A signed-in service whose friend list is just Olivia.
    private func makeService(friendUIDs: Set<String> = ["olivia"]) async -> (SharingService, AccountProvider) {
        let accounts = FakeAccountBackend(auth: auth)
        await accounts.setIdentity(oliviaKey.publicIdentity, for: "olivia")
        let provider = AccountProvider(auth: auth, accounts: accounts, keyStore: InMemoryKeyStore())
        let service = SharingService(accountProvider: provider, backend: backend, friends: friends, accounts: accounts, background: background, deviceId: "phone", defaults: isolatedDefaults())
        service.currentLocation = { [start] in (start, false) }
        provider.set(me)
        _ = await eventually { friends.hasFriendListener }
        friends.sendFriends(friendUIDs)
        try? await Task.sleep(for: .milliseconds(20))
        return (service, provider)
    }

    private func oliviasLocation(in share: OutgoingShare?) throws -> SharedLocation? {
        guard let box = share?.location else { return nil }
        return try Sealing.open(SharedLocation.self, from: box, sender: me.identity.publicIdentity, senderUid: "me", recipient: oliviaKey, recipientUid: "olivia")
    }

    @Test func sharingWithAFriendUploadsASealedLocationFromThisDevice() async throws {
        let (service, _) = await makeService()

        try await service.setSharing(true, with: "olivia")

        #expect(service.settings == SharingSettings(isEnabled: true, friendUIDs: ["olivia"], activeDeviceId: "phone"))
        #expect(background.isMonitoring)
        let location = try oliviasLocation(in: backend.writtenShares.last)
        #expect(location?.latitude == start.latitude)
        #expect(backend.writtenShares.last?.recipientUid == "olivia")
    }

    @Test func foregroundReadingsAreThrottled() async throws {
        let (service, _) = await makeService()
        try await service.setSharing(true, with: "olivia")
        await service.handleForeground(start, isApproximate: false)
        let afterFirst = backend.writtenShares.count

        await service.handleForeground(location(metersNorth: 100, secondsLater: 10), isApproximate: false)
        #expect(backend.writtenShares.count == afterFirst, "Too soon")

        await service.handleForeground(location(metersNorth: 100, secondsLater: 60), isApproximate: false)
        #expect(backend.writtenShares.count == afterFirst + 1)
    }

    @Test func stoppingClearsTheLocationButKeepsTheProfile() async throws {
        let (service, _) = await makeService()
        try await service.setSharing(true, with: "olivia")

        try await service.setSharing(false, with: "olivia")

        let last = try #require(backend.writtenShares.last)
        #expect(last.recipientUid == "olivia")
        #expect(last.location == nil)
        #expect(!service.settings.friendUIDs.contains("olivia"))
    }

    @Test func anotherActiveDeviceMeansNoUploadsHere() async throws {
        let (service, _) = await makeService()
        try await backend.saveSharingSettings(SharingSettings(isEnabled: true, friendUIDs: ["olivia"], activeDeviceId: "ipad"), for: "me")
        #expect(await eventually { service.settings.activeDeviceId == "ipad" })

        await service.handleForeground(start, isApproximate: false)

        #expect(backend.writtenShares.isEmpty)
        #expect(!service.isThisDeviceActive)
        #expect(!background.isMonitoring)
    }

    @Test func formerFriendsAreSkipped() async throws {
        let (service, _) = await makeService()
        try await backend.saveSharingSettings(SharingSettings(isEnabled: true, friendUIDs: ["olivia", "former-friend"], activeDeviceId: "phone"), for: "me")
        #expect(await eventually { service.settings.friendUIDs.count == 2 })

        await service.handleForeground(start, isApproximate: false)

        #expect(backend.writtenShares.map(\.recipientUid) == ["olivia"])
    }

    @Test func signingOutStopsBackgroundMonitoring() async throws {
        let (service, provider) = await makeService()
        try await service.setSharing(true, with: "olivia")

        provider.set(nil)

        #expect(!background.isMonitoring)
        #expect(service.settings == .off)
    }
}

@MainActor
struct AlertServiceTests {
    private let me = Account(uid: "me", identity: .generate(), profile: Profile(displayName: "Me", avatar: Avatar(emoji: nil, color: .red)))
    private let olivia = Account(uid: "olivia", identity: .generate(), profile: Profile(displayName: "Olivia", avatar: Avatar(emoji: nil, color: .blue)))
    private let backend = InMemorySharingAndAlerts()
    private let geofences = InMemoryGeofences()
    private let auth = FakeAuthBackend(signedInAs: "me")

    private func makeService() async -> AlertService {
        let accounts = FakeAccountBackend(auth: auth)
        await accounts.setIdentity(olivia.identity.publicIdentity, for: "olivia")
        let provider = AccountProvider(auth: auth, accounts: accounts, keyStore: InMemoryKeyStore())
        let service = AlertService(accountProvider: provider, backend: backend, accounts: accounts, geofences: geofences, defaults: isolatedDefaults())
        provider.set(me)
        _ = await eventually { await geofences.listenerCount > 0 }
        return service
    }

    /// Olivia asks to be told when "me" arrives at or leaves Home.
    private func oliviaSetsAlert(id: String = "alert-1", trigger: AlertTrigger = .arrive) async throws {
        let request = AlertRequest(id: id, placeName: "Home", latitude: 1, longitude: 2, radius: 200, trigger: trigger)
        try await backend.createAlertRequest(AlertPlanner.requestDocument(request, from: olivia, to: "me", identity: me.identity.publicIdentity))
    }

    @Test func alertsOnTheUserBecomeMonitoredRegions() async throws {
        let service = await makeService()

        try await oliviaSetsAlert()

        #expect(await eventually { await geofences.alerts["alert-1"] != nil })
        #expect(await eventually { service.alertsOnMe.first?.request?.placeName == "Home" })
    }

    @Test func blockingARequesterStopsMonitoringTheirAlerts() async throws {
        let service = await makeService()
        try await oliviaSetsAlert()
        #expect(await eventually { await geofences.alerts["alert-1"] != nil })

        try await service.updatePreferences { $0.blockedAlertRequesters.insert("olivia") }

        #expect(await eventually { await geofences.alerts.isEmpty })
    }

    @Test func arrivingSendsTheRequesterAnEventOnlyAfterARealTransition() async throws {
        _ = await makeService()
        try await oliviaSetsAlert()
        #expect(await eventually { await geofences.alerts["alert-1"] != nil })

        await geofences.send(GeofenceEvent(id: "alert-1", state: .inside))
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.postedEvents.isEmpty, "Already inside when the alert was set")

        await geofences.send(GeofenceEvent(id: "alert-1", state: .outside))
        await geofences.send(GeofenceEvent(id: "alert-1", state: .inside))

        #expect(await eventually { backend.postedEvents.count == 1 })
        #expect(backend.postedEvents.first?.from == "me")
        #expect(backend.postedEvents.first?.to == "olivia")
    }

    @Test func requesterCreatesListsAndDeletesAlerts() async throws {
        let service = await makeService()
        let friend = Friend(id: "olivia", displayName: "Olivia", avatar: Avatar(emoji: nil, color: .blue), identity: olivia.identity.publicIdentity)

        try await service.createAlert(on: friend, placeName: "  Work ", latitude: 1, longitude: 2, radius: 300, trigger: .leave)

        var listed: [SetAlert] = []
        for try await alerts in service.alertsSet(on: "olivia") {
            listed = alerts
            break
        }
        let alert = try #require(listed.first)
        #expect(alert.request.placeName == "Work")
        #expect(alert.request.trigger == .leave)

        try await service.deleteAlert(alert.id, on: "olivia")
        for try await alerts in service.alertsSet(on: "olivia") {
            #expect(alerts.isEmpty)
            break
        }
    }

    @Test func creatingAnAlertNeedsTheFriendsKey() async {
        let service = await makeService()
        let friend = Friend(id: "olivia", displayName: "Olivia", avatar: Avatar(emoji: nil, color: .blue))

        await #expect(throws: AlertServiceError.self) {
            try await service.createAlert(on: friend, placeName: "Work", latitude: 1, longitude: 2, radius: 300, trigger: .leave)
        }
    }
}
