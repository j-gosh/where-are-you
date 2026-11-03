//
//  BackgroundLocation.swift
//  where-are-you
//

import CoreLocation
import OSLog

/// Location while the app isn't on screen: significant-change monitoring (which relaunches the
/// app after roughly 500 m) and one-off fixes for background refresh. Needs Always permission.
@MainActor
protocol BackgroundLocationProviding: AnyObject {
    var onLocation: ((UserLocation) -> Void)? { get set }
    var isAlwaysAuthorized: Bool { get }
    var isAccuracyReduced: Bool { get }
    func startSignificantChanges()
    func stopSignificantChanges()
    /// One fresh fix.
    func requestLocation() async throws -> UserLocation
}

@MainActor
final class SignificantChangeMonitor: NSObject, BackgroundLocationProviding {
    // Created on the main thread, so delegate callbacks arrive on the main thread.
    private let manager = CLLocationManager()
    private var pendingRequests: [CheckedContinuation<UserLocation, Error>] = []

    var onLocation: ((UserLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAlwaysAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    var isAccuracyReduced: Bool {
        manager.accuracyAuthorization == .reducedAccuracy
    }

    func startSignificantChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            Logger.location.notice("Significant-change monitoring isn't available on this device")
            return
        }
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopSignificantChanges() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    func requestLocation() async throws -> UserLocation {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(continuation)
            manager.requestLocation()
        }
    }
}

extension SignificantChangeMonitor: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let location = UserLocation(latest)
        let waiting = pendingRequests
        pendingRequests = []
        if waiting.isEmpty {
            onLocation?(location)
        } else {
            waiting.forEach { $0.resume(returning: location) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Logger.location.error("Background location failed: \(error.localizedDescription, privacy: .public)")
        let waiting = pendingRequests
        pendingRequests = []
        waiting.forEach { $0.resume(throwing: error) }
    }
}
