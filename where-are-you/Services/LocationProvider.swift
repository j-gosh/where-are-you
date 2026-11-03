//
//  LocationProvider.swift
//  where-are-you
//

import CoreLocation
import OSLog

enum LocationAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .denied
        }
    }

    var allowsUpdates: Bool {
        self == .whenInUse || self == .always
    }
}

/// The current user's own position.
struct UserLocation: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Radius of uncertainty, in meters.
    var horizontalAccuracy: Double
    var timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension UserLocation {
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }
}

enum LocationReading: Sendable, Equatable {
    case location(UserLocation)
    /// The device can't determine its position right now (no signal, Airplane Mode, ...).
    case unavailable
}

/// The Core Location surface `LocationService` depends on, so tests can script it.
@MainActor
protocol LocationProvider: AnyObject {
    var authorization: LocationAuthorization { get }
    var isAccuracyReduced: Bool { get }
    /// Called whenever authorization or accuracy authorization changes.
    var onAuthorizationChange: (() -> Void)? { get set }

    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    /// Live location readings until the consuming task is cancelled.
    func readings() -> AsyncStream<LocationReading>
}

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider {
    // Created on the main thread, so Core Location calls the delegate on the main thread.
    private let manager = CLLocationManager()

    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    var isAccuracyReduced: Bool {
        manager.accuracyAuthorization == .reducedAccuracy
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func readings() -> AsyncStream<LocationReading> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location {
                            continuation.yield(.location(UserLocation(location)))
                        } else if update.locationUnavailable {
                            continuation.yield(.unavailable)
                        }
                        // Authorization problems arrive through the delegate instead.
                    }
                } catch {
                    Logger.location.error("Live location updates failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension CoreLocationProvider: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?()
    }
}
