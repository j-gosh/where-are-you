//
//  LocationServiceTests.swift
//  where-are-youTests
//

import Foundation
import Testing
@testable import where_are_you

@MainActor
struct LocationServiceTests {
    private let sampleLocation = UserLocation(latitude: 51.5, longitude: -0.12, horizontalAccuracy: 5, timestamp: .now)

    @Test func startNeverPromptsOrStreamsWithoutPermission() async {
        let provider = FakeLocationProvider(authorization: .notDetermined)
        let service = LocationService(provider: provider)

        service.start()

        #expect(provider.whenInUseRequests == 0)
        #expect(service.status == .needsPermission)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(provider.activeStreams == 0, "Must not stream before permission is granted")
    }

    @Test func requestPermissionAsksWhenUndetermined() {
        let provider = FakeLocationProvider(authorization: .notDetermined)
        let service = LocationService(provider: provider)

        service.requestPermission()

        #expect(provider.whenInUseRequests == 1)
    }

    @Test(arguments: [LocationAuthorization.whenInUse, .always, .denied, .restricted])
    func requestPermissionDoesNotAskAgain(authorization: LocationAuthorization) {
        let provider = FakeLocationProvider(authorization: authorization)
        let service = LocationService(provider: provider)

        service.requestPermission()

        #expect(provider.whenInUseRequests == 0)
    }

    @Test func grantingPermissionStartsStreaming() async {
        let provider = FakeLocationProvider(authorization: .notDetermined)
        let service = LocationService(provider: provider)
        service.start()

        provider.simulateAuthorizationChange(to: .whenInUse)
        #expect(service.status == .locating)
        #expect(await eventually { provider.activeStreams == 1 })

        provider.send(.location(sampleLocation))
        #expect(await eventually { service.status == .available(sampleLocation) })
    }

    @Test func deniedReportsDeniedAndDoesNotStream() async {
        let provider = FakeLocationProvider(authorization: .denied)
        let service = LocationService(provider: provider)

        service.start()

        #expect(service.status == .denied)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(provider.activeStreams == 0)
    }

    @Test func revokingPermissionClearsLocationAndStopsStreaming() async {
        let provider = FakeLocationProvider(authorization: .whenInUse)
        let service = LocationService(provider: provider)
        service.start()
        #expect(await eventually { provider.activeStreams == 1 })
        provider.send(.location(sampleLocation))
        #expect(await eventually { service.userLocation == sampleLocation })

        provider.simulateAuthorizationChange(to: .denied)

        #expect(service.userLocation == nil)
        #expect(service.status == .denied)
        #expect(await eventually { provider.activeStreams == 0 })
    }

    @Test func unavailableReadingIsReportedUntilNextFix() async {
        let provider = FakeLocationProvider(authorization: .whenInUse)
        let service = LocationService(provider: provider)
        service.start()
        #expect(await eventually { provider.activeStreams == 1 })

        provider.send(.unavailable)
        #expect(await eventually { service.status == .unavailable })

        provider.send(.location(sampleLocation))
        #expect(await eventually { service.status == .available(sampleLocation) })
    }

    @Test func stopEndsTheStream() async {
        let provider = FakeLocationProvider(authorization: .always)
        let service = LocationService(provider: provider)
        service.start()
        #expect(await eventually { provider.activeStreams == 1 })

        service.stop()

        #expect(await eventually { provider.activeStreams == 0 })
    }

    @Test func startingTwiceKeepsOneStream() async {
        let provider = FakeLocationProvider(authorization: .whenInUse)
        let service = LocationService(provider: provider)

        service.start()
        service.start()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(provider.activeStreams == 1)
    }

    @Test func restartsAfterStreamEndsOnItsOwn() async {
        let provider = FakeLocationProvider(authorization: .whenInUse)
        let service = LocationService(provider: provider)
        service.start()
        #expect(await eventually { provider.activeStreams == 1 })

        provider.finishStream()
        #expect(await eventually { provider.activeStreams == 0 })
        service.start()

        #expect(await eventually { provider.activeStreams == 1 })
    }

    @Test func reportsReducedAccuracy() {
        let provider = FakeLocationProvider(authorization: .notDetermined)
        let service = LocationService(provider: provider)

        provider.simulateAuthorizationChange(to: .whenInUse, accuracyReduced: true)

        #expect(service.isAccuracyReduced)
    }

    @Test func requestAlwaysForwardsToProvider() {
        let provider = FakeLocationProvider(authorization: .whenInUse)
        let service = LocationService(provider: provider)

        service.requestAlwaysAuthorization()

        #expect(provider.alwaysRequests == 1)
    }
}
