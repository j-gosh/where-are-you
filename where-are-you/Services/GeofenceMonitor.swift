//
//  GeofenceMonitor.swift
//  where-are-you
//

import CoreLocation
import OSLog
import WAYCore

struct GeofenceEvent: Sendable, Equatable {
    let id: String
    /// `nil` while unknown or no longer monitored.
    let state: GeofenceState?
}

/// Region monitoring for alerts set on the user. iOS keeps watching after the app quits and
/// relaunches it on a transition. Needs Always permission for that.
protocol GeofenceMonitoring: Sendable {
    func monitoredIDs() async -> Set<String>
    /// Adds or replaces the region for an alert.
    func add(_ alert: MonitoredAlert) async
    func remove(_ id: String) async
    /// Transitions, for as long as the caller listens. Start listening at launch.
    func events() async -> AsyncStream<GeofenceEvent>
}

/// `CLMonitor`, which allows one instance per name per process, so there's only ever one of these.
actor CoreLocationGeofences: GeofenceMonitoring {
    static let shared = CoreLocationGeofences()

    private var monitor: CLMonitor?

    private init() {}

    private func currentMonitor() async -> CLMonitor {
        if let monitor {
            return monitor
        }
        let monitor = await CLMonitor("WhereAreYouAlerts")
        self.monitor = monitor
        return monitor
    }

    func monitoredIDs() async -> Set<String> {
        Set(await currentMonitor().identifiers)
    }

    func add(_ alert: MonitoredAlert) async {
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: alert.request.latitude, longitude: alert.request.longitude),
            radius: alert.request.radius
        )
        await currentMonitor().add(condition, identifier: alert.id)
    }

    func remove(_ id: String) async {
        await currentMonitor().remove(id)
    }

    func events() async -> AsyncStream<GeofenceEvent> {
        let monitor = await currentMonitor()
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await event in await monitor.events {
                        continuation.yield(GeofenceEvent(id: event.identifier, state: GeofenceState(event.state)))
                    }
                } catch {
                    Logger.alerts.error("Region monitoring stopped: \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension GeofenceState {
    init?(_ state: CLMonitor.Event.State) {
        switch state {
        case .satisfied: self = .inside
        case .unsatisfied: self = .outside
        default: return nil
        }
    }
}
