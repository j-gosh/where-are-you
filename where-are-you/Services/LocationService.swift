//
//  LocationService.swift
//  where-are-you
//

import Foundation
import Observation

/// The current user's location and permission state. One instance lives for the whole app.
@MainActor
@Observable
final class LocationService {
    enum Status: Equatable {
        /// The user hasn't been asked for permission yet.
        case needsPermission
        case denied
        /// Blocked by Screen Time or device management; the user can't change it.
        case restricted
        /// Authorized and waiting for the first fix.
        case locating
        /// Authorized, but the device can't get a fix right now.
        case unavailable
        case available(UserLocation)
    }

    private(set) var authorization: LocationAuthorization
    private(set) var isAccuracyReduced: Bool
    private(set) var userLocation: UserLocation?
    private(set) var isLocationUnavailable = false

    var status: Status {
        switch authorization {
        case .notDetermined:
            return .needsPermission
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .whenInUse, .always:
            if isLocationUnavailable { return .unavailable }
            if let userLocation { return .available(userLocation) }
            return .locating
        }
    }

    /// Each new fix and whether it's approximate. Location sharing listens here.
    @ObservationIgnored var onLocation: ((UserLocation, Bool) -> Void)?

    @ObservationIgnored private let provider: LocationProvider
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    // Lets a finished stream tell whether it is still the current one.
    @ObservationIgnored private var streamGeneration = 0

    init(provider: LocationProvider) {
        self.provider = provider
        authorization = provider.authorization
        isAccuracyReduced = provider.isAccuracyReduced
        provider.onAuthorizationChange = { [weak self] in
            self?.authorizationDidChange()
        }
    }

    /// Tracks the user's location whenever permission allows. Never prompts; see `requestPermission()`.
    func start() {
        isRunning = true
        updateStreaming()
    }

    /// Shows the system When In Use prompt, if the user hasn't answered it yet.
    func requestPermission() {
        guard authorization == .notDetermined else { return }
        provider.requestWhenInUseAuthorization()
    }

    func stop() {
        isRunning = false
        updateStreaming()
    }

    /// Asks to upgrade to Always. iOS shows this prompt at most once; after that the user has to use Settings.
    func requestAlwaysAuthorization() {
        provider.requestAlwaysAuthorization()
    }

    private func authorizationDidChange() {
        authorization = provider.authorization
        isAccuracyReduced = provider.isAccuracyReduced
        if !authorization.allowsUpdates {
            userLocation = nil
        }
        updateStreaming()
    }

    private func updateStreaming() {
        let shouldStream = isRunning && authorization.allowsUpdates
        if shouldStream {
            guard updatesTask == nil else { return }
            streamGeneration += 1
            let generation = streamGeneration
            updatesTask = Task { [weak self, provider] in
                for await reading in provider.readings() {
                    self?.handle(reading)
                }
                self?.streamDidEnd(generation: generation)
            }
        } else {
            updatesTask?.cancel()
            updatesTask = nil
            isLocationUnavailable = false
        }
    }

    private func handle(_ reading: LocationReading) {
        switch reading {
        case .location(let location):
            userLocation = location
            isLocationUnavailable = false
            onLocation?(location, isAccuracyReduced)
        case .unavailable:
            isLocationUnavailable = true
        }
    }

    // A stream that ends on its own (Core Location error) is restarted by the next start().
    private func streamDidEnd(generation: Int) {
        guard generation == streamGeneration else { return }
        updatesTask = nil
    }
}
