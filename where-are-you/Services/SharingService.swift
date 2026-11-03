//
//  SharingService.swift
//  where-are-you
//

import BackgroundTasks
import Foundation
import Observation
import OSLog
import WAYCore

/// Shares the user's location with the friends they chose, from their active device only.
///
/// Foreground readings come from `LocationService`. In the background, significant-change
/// monitoring and background refresh feed it, possibly in a fresh process with no UI, in which
/// case the account and settings are loaded directly.
@MainActor
@Observable
final class SharingService {
    static let refreshTaskIdentifier = "\(Bundle.main.bundleIdentifier ?? "where-are-you").heartbeat"

    private(set) var settings: SharingSettings = .off
    private(set) var lastUploadDate: Date?
    private(set) var lastUploadFailed = false
    let deviceId: String

    var isThisDeviceActive: Bool {
        settings.activeDeviceId == deviceId
    }

    /// The current location and whether it's approximate, from `LocationService`.
    @ObservationIgnored var currentLocation: () -> (location: UserLocation, isApproximate: Bool)? = { nil }

    @ObservationIgnored private let accountProvider: AccountProvider
    @ObservationIgnored private let backend: SharingBackend
    @ObservationIgnored private let friends: FriendsBackend
    @ObservationIgnored private let accounts: AccountBackend
    @ObservationIgnored private let background: BackgroundLocationProviding
    @ObservationIgnored private let policy: UploadPolicy
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var friendUIDs: Set<String>?
    @ObservationIgnored private var identities: [String: PublicIdentity] = [:]
    @ObservationIgnored private var identitiesLoadedAt: Date?
    @ObservationIgnored private var lastUploaded: SharedLocation?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []

    /// Remembers across launches whether this device uploads, so a background relaunch can
    /// restart monitoring before anything loads.
    private static let uploadsFlagKey = "sharing.uploadsFromThisDevice"
    private static let identityCacheLifetime: TimeInterval = 30 * 60

    init(
        accountProvider: AccountProvider,
        backend: SharingBackend,
        friends: FriendsBackend,
        accounts: AccountBackend,
        background: BackgroundLocationProviding,
        deviceId: String,
        policy: UploadPolicy = UploadPolicy(),
        defaults: UserDefaults = .standard
    ) {
        self.accountProvider = accountProvider
        self.backend = backend
        self.friends = friends
        self.accounts = accounts
        self.background = background
        self.deviceId = deviceId
        self.policy = policy
        self.defaults = defaults

        background.onLocation = { [weak self] location in
            Task { await self?.handleBackground(location) }
        }
        // iOS only delivers the location that relaunched the app if monitoring restarts at launch.
        if defaults.bool(forKey: Self.uploadsFlagKey) {
            background.startSignificantChanges()
        }
        accountProvider.observe { [weak self] account in
            self?.setAccount(account)
        }
    }

    private func setAccount(_ account: Account?) {
        listeners.forEach { $0.cancel() }
        listeners = []
        self.account = account
        friendUIDs = nil
        identities = [:]
        lastUploaded = nil
        guard let account else {
            settings = .off
            applySettings()
            return
        }

        let uid = account.uid
        listeners.append(Task { [weak self, backend] in
            do {
                for try await settings in backend.sharingSettings(of: uid) {
                    self?.settings = settings
                    self?.applySettings()
                }
            } catch {
                Logger.sharing.error("Sharing settings listener failed: \(error.localizedDescription, privacy: .public)")
            }
        })
        listeners.append(Task { [weak self, friends] in
            do {
                for try await uids in friends.friendUIDs(of: uid) {
                    self?.friendUIDs = uids
                }
            } catch {
                Logger.sharing.error("Friends listener failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func applySettings() {
        let uploads = settings.uploads(from: deviceId)
        defaults.set(uploads, forKey: Self.uploadsFlagKey)
        if uploads {
            background.startSignificantChanges()
            scheduleRefresh()
        } else {
            background.stopSignificantChanges()
        }
    }

    // MARK: Readings

    func handleForeground(_ location: UserLocation, isApproximate: Bool) async {
        await upload(sharedLocation(location, isApproximate: isApproximate))
    }

    func handleBackground(_ location: UserLocation) async {
        let task = BackgroundTask.begin("Share location")
        defer { task.end() }
        await upload(sharedLocation(location, isApproximate: background.isAccuracyReduced))
    }

    /// Background refresh: upload a fresh fix even without movement, so friends see the location
    /// is current. iOS decides when (and whether) this runs.
    func refreshInBackground() async {
        defer { scheduleRefresh() }
        guard defaults.bool(forKey: Self.uploadsFlagKey) else { return }
        do {
            let location = try await background.requestLocation()
            await upload(sharedLocation(location, isApproximate: background.isAccuracyReduced))
        } catch {
            Logger.sharing.error("Background refresh couldn't get a location: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: policy.heartbeatInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator, and when Background App Refresh is off.
            Logger.sharing.notice("Couldn't schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sharedLocation(_ location: UserLocation, isApproximate: Bool) -> SharedLocation {
        SharedLocation(
            latitude: location.latitude,
            longitude: location.longitude,
            horizontalAccuracy: max(0, location.horizontalAccuracy),
            isApproximate: isApproximate,
            timestamp: location.timestamp
        )
    }

    // MARK: Uploading

    /// - Parameters:
    ///   - force: Skip the upload policy (the user just changed who they share with).
    ///   - recipients: Upload only to these friends, e.g. one just added.
    private func upload(_ location: SharedLocation, force: Bool = false, recipients: Set<String>? = nil) async {
        do {
            guard try await prepare(), let account, settings.uploads(from: deviceId) else { return }
            guard force || policy.shouldUpload(location, after: lastUploaded) else { return }
            var targets = settings.friendUIDs.intersection(friendUIDs ?? [])
            if let recipients {
                targets.formIntersection(recipients)
            }
            let shares = try LocationSharer.shares(for: location, account: account, recipients: try await identities(for: targets))
            try await backend.writeShares(shares, from: account.uid)
            if recipients == nil {
                lastUploaded = location
            }
            lastUploadDate = .now
            lastUploadFailed = false
        } catch {
            Logger.sharing.error("Uploading the location failed: \(error.localizedDescription, privacy: .public)")
            lastUploadFailed = true
        }
    }

    /// After a background relaunch, nothing has loaded yet: load what an upload needs directly.
    private func prepare() async throws -> Bool {
        if account == nil {
            guard let loaded = try await accountProvider.load() else { return false }
            account = loaded
            settings = try await backend.fetchSharingSettings(of: loaded.uid)
        }
        if friendUIDs == nil, let account {
            friendUIDs = try await firstValue(of: friends.friendUIDs(of: account.uid)) ?? []
        }
        return account != nil
    }

    private func identities(for uids: Set<String>) async throws -> [String: PublicIdentity] {
        if let loadedAt = identitiesLoadedAt, Date.now.timeIntervalSince(loadedAt) > Self.identityCacheLifetime {
            // Friends' keys can change; refresh now and then.
            identities = [:]
            identitiesLoadedAt = nil
        }
        identitiesLoadedAt = identitiesLoadedAt ?? .now
        for uid in uids where identities[uid] == nil {
            identities[uid] = try await accounts.publicIdentity(of: uid)
        }
        return identities.filter { uids.contains($0.key) }
    }

    // MARK: Actions. Callers show errors.

    /// The master switch. Turning it on makes this device the active one if none is.
    func setSharingEnabled(_ isEnabled: Bool) async throws {
        var updated = settings
        updated.isEnabled = isEnabled
        if isEnabled, updated.activeDeviceId == nil {
            updated.activeDeviceId = deviceId
        }
        let previouslySharedWith = settings.isEnabled ? settings.friendUIDs : []
        try await save(updated)
        if isEnabled {
            await uploadCurrentLocation()
        } else {
            try await stopSharing(with: previouslySharedWith)
        }
    }

    /// Sharing with one friend. Turning it on also turns on the master switch.
    func setSharing(_ isSharing: Bool, with friendUid: String) async throws {
        var updated = settings
        if isSharing {
            updated.friendUIDs.insert(friendUid)
            updated.isEnabled = true
            updated.activeDeviceId = updated.activeDeviceId ?? deviceId
        } else {
            updated.friendUIDs.remove(friendUid)
        }
        try await save(updated)
        if isSharing {
            await uploadCurrentLocation(to: [friendUid])
        } else {
            try await stopSharing(with: [friendUid])
        }
    }

    /// "Use This iPhone as My Location".
    func useThisDevice() async throws {
        var updated = settings
        updated.activeDeviceId = deviceId
        try await save(updated)
        await uploadCurrentLocation()
    }

    private func save(_ updated: SharingSettings) async throws {
        guard let account else { return }
        try await backend.saveSharingSettings(updated, for: account.uid)
        settings = updated
        applySettings()
    }

    private func uploadCurrentLocation(to recipients: Set<String>? = nil) async {
        guard let current = currentLocation() else { return }
        await upload(sharedLocation(current.location, isApproximate: current.isApproximate), force: true, recipients: recipients)
    }

    /// Clears the location from these friends' shares (keeping the profile).
    private func stopSharing(with uids: Set<String>) async throws {
        guard let account else { return }
        let targets = uids.intersection(friendUIDs ?? uids)
        guard !targets.isEmpty else { return }
        let shares = try LocationSharer.stoppedShares(account: account, recipients: try await identities(for: targets))
        try await backend.writeShares(shares, from: account.uid)
    }
}
