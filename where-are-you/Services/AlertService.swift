//
//  AlertService.swift
//  where-are-you
//

import Foundation
import Observation
import OSLog
import WAYCore

/// One alert a friend set on the user, for Settings → Alerts on You.
struct IncomingAlert: Identifiable, Equatable {
    let id: String
    let requesterUid: String
    /// `nil` if it couldn't be decrypted.
    let request: AlertRequest?
}

enum AlertServiceError: LocalizedError {
    case notReady

    var errorDescription: String? {
        String(localized: "Their encryption key hasn't loaded yet. Try again in a moment.")
    }
}

/// Both sides of arrive/leave alerts.
///
/// As the watched person: turns friends' requests into monitored regions, and when one fires,
/// sends the requester an encrypted event. Regions and their last states are stored on device,
/// so a relaunch for a region event can act without network reads.
///
/// As the requester: creates, lists and deletes alerts on friends.
@MainActor
@Observable
final class AlertService {
    private(set) var alertsOnMe: [IncomingAlert] = []
    private(set) var preferences = AlertPreferences()
    /// Allowed alerts beyond iOS's limit of monitored regions.
    private(set) var overLimitCount = 0

    @ObservationIgnored private let accountProvider: AccountProvider
    @ObservationIgnored private let backend: AlertsBackend
    @ObservationIgnored private let accounts: AccountBackend
    @ObservationIgnored private let geofences: GeofenceMonitoring
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var documents: [AlertRequestDocument] = []
    @ObservationIgnored private var identities: [String: PublicIdentity] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var eventsTask: Task<Void, Never>?

    private static let monitoredKey = "alerts.monitored"
    private static let statesKey = "alerts.states"
    static let eventLifetime: TimeInterval = 12 * 60 * 60

    init(accountProvider: AccountProvider, backend: AlertsBackend, accounts: AccountBackend, geofences: GeofenceMonitoring, defaults: UserDefaults = .standard) {
        self.accountProvider = accountProvider
        self.backend = backend
        self.accounts = accounts
        self.geofences = geofences
        self.defaults = defaults

        // Listen from launch: a relaunch for a region event delivers it right away.
        eventsTask = Task { [weak self, geofences] in
            for await event in await geofences.events() {
                await self?.handle(event)
            }
        }
        accountProvider.observe { [weak self] account in
            self?.setAccount(account)
        }
    }

    private func setAccount(_ account: Account?) {
        listeners.forEach { $0.cancel() }
        listeners = []
        self.account = account
        documents = []
        identities = [:]
        guard let account else {
            alertsOnMe = []
            preferences = AlertPreferences()
            overLimitCount = 0
            Task { await apply([]) }
            return
        }

        let uid = account.uid
        listeners.append(Task { [weak self, backend] in
            do {
                for try await preferences in backend.alertPreferences(of: uid) {
                    self?.preferences = preferences
                    await self?.sync()
                }
            } catch {
                Logger.alerts.error("Alert preferences listener failed: \(error.localizedDescription, privacy: .public)")
            }
        })
        listeners.append(Task { [weak self, backend] in
            do {
                for try await documents in backend.alertRequests(on: uid) {
                    self?.documents = documents
                    await self?.sync()
                }
            } catch {
                Logger.alerts.error("Alert requests listener failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    // MARK: Watched side

    private func sync() async {
        guard let account else { return }
        for uid in Set(documents.map(\.requesterUid)) where identities[uid] == nil {
            do {
                identities[uid] = try await accounts.publicIdentity(of: uid)
            } catch {
                Logger.alerts.error("Loading a requester's key failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        alertsOnMe = documents.map { document in
            let request = identities[document.requesterUid].flatMap { identity in
                try? Sealing.open(AlertRequest.self, from: document.payload, sender: identity, senderUid: document.requesterUid, recipient: account.identity, recipientUid: account.uid)
            }
            return IncomingAlert(id: document.id, requesterUid: document.requesterUid, request: request)
        }
        let plan = AlertPlanner.plan(documents: documents, account: account, identities: identities, preferences: preferences)
        overLimitCount = plan.overLimit
        await apply(plan.monitored)
    }

    /// Makes the monitored regions match `alerts`.
    private func apply(_ alerts: [MonitoredAlert]) async {
        let wanted = Dictionary(alerts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = monitored
        var states = self.states
        for id in await geofences.monitoredIDs() where wanted[id] == nil {
            await geofences.remove(id)
            states[id] = nil
        }
        let current = await geofences.monitoredIDs()
        for alert in alerts where !current.contains(alert.id) || previous[alert.id] != alert {
            await geofences.add(alert)
            states[alert.id] = nil
        }
        monitored = wanted
        self.states = states
    }

    private func handle(_ event: GeofenceEvent) async {
        guard let state = event.state, let alert = monitored[event.id] else { return }
        let previous = states[event.id]
        states[event.id] = state
        guard AlertPlanner.shouldNotify(trigger: alert.request.trigger, previous: previous, current: state) else { return }

        let task = BackgroundTask.begin("Send location alert")
        defer { task.end() }
        do {
            guard let account = try await accountProvider.load() else { return }
            // Re-check at the moment of sending; the user may have changed their mind.
            let preferences = self.account == nil ? try await backend.fetchAlertPreferences(of: account.uid) : preferences
            guard preferences.allowsAlerts(from: alert.requesterUid) else { return }
            let payload = try AlertPlanner.sealedEvent(for: alert, account: account, at: .now)
            try await backend.postNotificationEvent(from: account.uid, to: alert.requesterUid, payload: payload, expiresAt: Date(timeIntervalSinceNow: Self.eventLifetime))
        } catch {
            Logger.alerts.error("Sending an alert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Requester side. Callers show errors.

    func createAlert(on friend: Friend, placeName: String, latitude: Double, longitude: Double, radius: Double, trigger: AlertTrigger) async throws {
        guard let account, let identity = friend.identity else { throw AlertServiceError.notReady }
        let request = AlertRequest(
            id: UUID().uuidString,
            placeName: placeName.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            trigger: trigger
        )
        try await backend.createAlertRequest(AlertPlanner.requestDocument(request, from: account, to: friend.id, identity: identity))
    }

    /// The alerts the user has set on one friend, decrypted from their own copies.
    func alertsSet(on friendUid: String) -> AsyncThrowingStream<[SetAlert], Error> {
        guard let account else {
            return AsyncThrowingStream { $0.finish() }
        }
        let requests = backend.alertRequests(setBy: account.uid, on: friendUid)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await documents in requests {
                        continuation.yield(AlertPlanner.setAlerts(documents: documents, account: account))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deleteAlert(_ id: String, on friendUid: String) async throws {
        try await backend.deleteAlertRequest(id: id, on: friendUid)
    }

    func removeAlertOnMe(_ id: String) async throws {
        guard let account else { return }
        try await backend.deleteAlertRequest(id: id, on: account.uid)
    }

    func updatePreferences(_ change: (inout AlertPreferences) -> Void) async throws {
        guard let account else { return }
        var updated = preferences
        change(&updated)
        try await backend.saveAlertPreferences(updated, for: account.uid)
        preferences = updated
        await sync()
    }

    // MARK: Storage

    private var monitored: [String: MonitoredAlert] {
        get { decoded(forKey: Self.monitoredKey) ?? [:] }
        set { encode(newValue, forKey: Self.monitoredKey) }
    }

    private var states: [String: GeofenceState] {
        get { decoded(forKey: Self.statesKey) ?? [:] }
        set { encode(newValue, forKey: Self.statesKey) }
    }

    private func decoded<Value: Decodable>(forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            Logger.alerts.error("Discarding unreadable alert state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Logger.alerts.error("Saving alert state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
