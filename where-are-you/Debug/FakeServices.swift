//
//  FakeServices.swift
//  where-are-you
//

#if DEBUG
import Foundation
import SwiftUI
import Synchronization
import WAYCore

/// Launch environment keys UI tests set to run the app against fakes.
/// UI tests run in another process, so they repeat these strings.
enum LaunchEnvironment {
    /// "1" swaps every service for a fake.
    static let fakeServices = "UITEST_FAKE_SERVICES"
    /// "denied", "restricted", "notDetermined", or "always". Defaults to When In Use.
    static let locationAuthorization = "UITEST_LOCATION_AUTH"
    /// "signedOut", "newUser" (signed in, no key or profile yet), or "ready" (the default).
    static let session = "UITEST_SESSION"
    /// "1" clears the app's UserDefaults first, so state like the location primer doesn't
    /// carry over from earlier runs on the same simulator.
    static let resetState = "UITEST_RESET_STATE"
}

extension AppDependencies {
    static var preview: AppDependencies {
        fake(environment: [:])
    }

    static func fake(environment: [String: String]) -> AppDependencies {
        if environment[LaunchEnvironment.resetState] == "1", let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        let authorization: LocationAuthorization = switch environment[LaunchEnvironment.locationAuthorization] {
        case "denied": .denied
        case "restricted": .restricted
        case "notDetermined": .notDetermined
        case "always": .always
        default: .whenInUse
        }
        let backend = FakeBackend(scenario: environment[LaunchEnvironment.session] ?? "ready")
        let accountProvider = AccountProvider(auth: backend.auth, accounts: backend.account, keyStore: backend.keyStore)
        let deviceId = DeviceIdentity.current()
        return wire(
            session: backend.makeSession(),
            accountProvider: accountProvider,
            locationService: LocationService(provider: StaticLocationProvider(authorization: authorization)),
            addressLookup: FixedAddressLookup(address: "1 Example Street, San Francisco"),
            makeFriendsRepository: { _ in FixtureFriendsRepository.bundled() },
            sharing: SharingService(
                accountProvider: accountProvider,
                backend: backend.sharingAndAlerts,
                friends: FixtureFriendsBackend(),
                accounts: backend.account,
                background: NoBackgroundLocation(),
                deviceId: deviceId
            ),
            alerts: AlertService(accountProvider: accountProvider, backend: backend.sharingAndAlerts, accounts: backend.account, geofences: InMemoryGeofences()),
            push: PushService(registrar: nil, deviceId: deviceId, accountProvider: accountProvider)
        )
    }
}

extension View {
    /// Fixture friends for previews of views below the signed-in root.
    func previewFriends() -> some View {
        modifier(PreviewFriends())
    }
}

private struct PreviewFriends: ViewModifier {
    @State private var store = FriendsStore(repository: FixtureFriendsRepository.bundled())

    func body(content: Content) -> some View {
        content
            .environment(store)
            .task { await store.observe() }
    }
}

/// In-memory auth, account storage, and key storage that agree with each other.
@MainActor
struct FakeBackend {
    static let testUID = "test-user"

    let auth: FakeAuthBackend
    let account: FakeAccountBackend
    let keyStore = InMemoryKeyStore()
    let reauthenticator = FakeAppleReauthenticator()
    let sharingAndAlerts = InMemorySharingAndAlerts()

    init(scenario: String) {
        switch scenario {
        case "signedOut":
            auth = FakeAuthBackend(signedInAs: nil)
            account = FakeAccountBackend(auth: auth)
        case "newUser":
            auth = FakeAuthBackend(signedInAs: Self.testUID)
            account = FakeAccountBackend(auth: auth)
        default:
            auth = FakeAuthBackend(signedInAs: Self.testUID)
            let key = IdentityKey.generate()
            try? keyStore.save(key, for: Self.testUID)
            let profile = Profile(displayName: "Test User", avatar: Avatar(emoji: nil, color: .teal))
            let box = try? Sealing.seal(profile, from: key, senderUid: Self.testUID, to: key.publicIdentity, recipientUid: Self.testUID)
            // Fixture friends' keys too, so sharing and alerts can seal for them.
            var identities = FixtureFriendsBackend.identities
            identities[Self.testUID] = key.publicIdentity
            account = FakeAccountBackend(
                auth: auth,
                identities: identities,
                profileBoxes: box.map { [Self.testUID: $0] } ?? [:]
            )
        }
    }

    func makeSession(isUsingEmulator: Bool = false) -> SessionModel {
        SessionModel(auth: auth, account: account, keyStore: keyStore, reauthenticator: reauthenticator, isUsingEmulator: isUsingEmulator)
    }
}

final class FakeAuthBackend: AuthBackend {
    private struct State {
        var uid: String?
        var listeners: [UUID: AsyncStream<String?>.Continuation] = [:]
        var revokedCodes: [String] = []
        var reauthenticationCount = 0
        var signInError: (any Error)?
    }

    private let state: Mutex<State>

    init(signedInAs uid: String?) {
        state = Mutex(State(uid: uid))
    }

    var currentUID: String? { state.withLock { $0.uid } }
    var revokedCodes: [String] { state.withLock { $0.revokedCodes } }
    var reauthenticationCount: Int { state.withLock { $0.reauthenticationCount } }

    func failSignIn(with error: any Error) {
        state.withLock { $0.signInError = error }
    }

    func userIDs() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            let uid = state.withLock { state in
                state.listeners[id] = continuation
                return state.uid
            }
            continuation.yield(uid)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
            }
        }
    }

    func signIn(with credential: AppleCredential) async throws -> String {
        if let error = state.withLock({ $0.signInError }) {
            throw error
        }
        let uid = "apple-\(credential.idToken)"
        setUID(uid)
        return uid
    }

    func reauthenticate(with credential: AppleCredential) async throws {
        try state.withLock { state in
            guard state.uid != nil else { throw CancellationError() }
            state.reauthenticationCount += 1
        }
    }

    func revokeAppleToken(authorizationCode: String) async throws {
        state.withLock { $0.revokedCodes.append(authorizationCode) }
    }

    func signOut() throws {
        setUID(nil)
    }

    private func setUID(_ uid: String?) {
        let listeners = state.withLock { state in
            state.uid = uid
            return Array(state.listeners.values)
        }
        for listener in listeners {
            listener.yield(uid)
        }
    }
}

actor FakeAccountBackend: AccountBackend {
    private let auth: FakeAuthBackend
    private(set) var identities: [String: PublicIdentity]
    private(set) var profileBoxes: [String: SealedBox]
    private(set) var deletedAccounts: [String] = []
    /// Thrown by every call while set.
    private var failure: (any Error)?

    init(auth: FakeAuthBackend, identities: [String: PublicIdentity] = [:], profileBoxes: [String: SealedBox] = [:]) {
        self.auth = auth
        self.identities = identities
        self.profileBoxes = profileBoxes
    }

    func setFailure(_ error: (any Error)?) {
        failure = error
    }

    func setIdentity(_ identity: PublicIdentity?, for uid: String) {
        identities[uid] = identity
    }

    func setProfileBox(_ box: SealedBox?, for uid: String) {
        profileBoxes[uid] = box
    }

    func publicIdentity(of uid: String) async throws -> PublicIdentity? {
        try checkFailure()
        return identities[uid]
    }

    func publishIdentity(_ identity: PublicIdentity, for uid: String) async throws {
        try checkFailure()
        identities[uid] = identity
    }

    func ownProfileBox(for uid: String) async throws -> SealedBox? {
        try checkFailure()
        return profileBoxes[uid]
    }

    func saveOwnProfileBox(_ box: SealedBox, for uid: String) async throws {
        try checkFailure()
        profileBoxes[uid] = box
    }

    func deleteAccount() async throws {
        try checkFailure()
        guard let uid = auth.currentUID else { return }
        identities[uid] = nil
        profileBoxes[uid] = nil
        deletedAccounts.append(uid)
    }

    private func checkFailure() throws {
        if let failure {
            throw failure
        }
    }
}

@MainActor
final class FakeAppleReauthenticator: AppleReauthenticator {
    /// Simulates the user closing the Apple sheet.
    var cancels = false
    private(set) var requestCount = 0

    func requestCredential() async throws -> AppleCredential {
        requestCount += 1
        if cancels {
            throw CancellationError()
        }
        return AppleCredential(idToken: "reauth-token", rawNonce: "nonce", authorizationCode: "authorization-code", fullName: nil)
    }
}

/// Always reports the same position, in San Francisco.
@MainActor
final class StaticLocationProvider: LocationProvider {
    let authorization: LocationAuthorization
    let isAccuracyReduced = false
    var onAuthorizationChange: (() -> Void)?

    private let location = UserLocation(
        latitude: 37.7749,
        longitude: -122.4194,
        horizontalAccuracy: 10,
        timestamp: .now
    )

    init(authorization: LocationAuthorization) {
        self.authorization = authorization
    }

    func requestWhenInUseAuthorization() {}

    func requestAlwaysAuthorization() {}

    func readings() -> AsyncStream<LocationReading> {
        let location = location
        return AsyncStream { continuation in
            continuation.yield(.location(location))
        }
    }
}

/// Friendships for the fixture friends in Preview Content/friends.json.
struct FixtureFriendsBackend: FriendsBackend {
    static let friendIDs: Set<String> = [
        "QW345DVJjdfe", "LSDLVJH234785", "3247DSVR324", "PWEIR234235235",
        "8234800DFLEV2345", "798237498DFBRE34", "0234870928374787", "808080283409JLHSJB",
    ]

    static var identities: [String: PublicIdentity] {
        Dictionary(uniqueKeysWithValues: friendIDs.compactMap { id in FriendFixture.fixtureIdentity(for: id).map { (id, $0) } })
    }

    func friendUIDs(of uid: String) -> AsyncThrowingStream<Set<String>, Error> {
        AsyncThrowingStream { $0.yield(Self.friendIDs) }
    }

    func incomingShares(for uid: String) -> AsyncThrowingStream<[ShareDocument], Error> {
        AsyncThrowingStream { $0.yield([]) }
    }

    func outgoingShare(from uid: String, to friendUid: String) async throws -> ShareDocument? { nil }
    func publishProfile(_ box: SealedBox, from uid: String, to friendUid: String) async throws {}
    func createInvite(token: String, inviterUid: String, inviterKeyId: String, expiresAt: Date) async throws {}
    func invite(token: String) async throws -> InviteDocument? { nil }
    func acceptInvite(token: String) async throws -> String { throw InviteError.expiredOrUsed }
    func removeFriend(_ friendUid: String) async throws {}
}

/// Sharing settings, shares, alert requests and preferences, kept in memory.
final class InMemorySharingAndAlerts: SharingBackend, AlertsBackend {
    private struct State {
        var settings: [String: SharingSettings] = [:]
        var writtenShares: [OutgoingShare] = []
        var requests: [String: AlertRequestDocument] = [:]
        var preferences: [String: AlertPreferences] = [:]
        var events: [(from: String, to: String)] = []
        var settingsListeners: [String: [AsyncThrowingStream<SharingSettings, Error>.Continuation]] = [:]
        var preferenceListeners: [String: [AsyncThrowingStream<AlertPreferences, Error>.Continuation]] = [:]
        var requestListeners: [(filter: @Sendable (AlertRequestDocument) -> Bool, continuation: AsyncThrowingStream<[AlertRequestDocument], Error>.Continuation)] = []
    }

    private let state = Mutex(State())

    var writtenShares: [OutgoingShare] { state.withLock { $0.writtenShares } }
    var postedEvents: [(from: String, to: String)] { state.withLock { $0.events } }

    // MARK: SharingBackend

    func sharingSettings(of uid: String) -> AsyncThrowingStream<SharingSettings, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SharingSettings.self)
        let current = state.withLock { state in
            state.settingsListeners[uid, default: []].append(continuation)
            return state.settings[uid] ?? .off
        }
        continuation.yield(current)
        return stream
    }

    func fetchSharingSettings(of uid: String) async throws -> SharingSettings {
        state.withLock { $0.settings[uid] ?? .off }
    }

    func saveSharingSettings(_ settings: SharingSettings, for uid: String) async throws {
        let listeners = state.withLock { state in
            state.settings[uid] = settings
            return state.settingsListeners[uid] ?? []
        }
        listeners.forEach { $0.yield(settings) }
    }

    func writeShares(_ shares: [OutgoingShare], from uid: String) async throws {
        state.withLock { $0.writtenShares.append(contentsOf: shares) }
    }

    // MARK: AlertsBackend

    func alertRequests(on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error> {
        listenToRequests { $0.targetUid == targetUid }
    }

    func alertRequests(setBy requesterUid: String, on targetUid: String) -> AsyncThrowingStream<[AlertRequestDocument], Error> {
        listenToRequests { $0.requesterUid == requesterUid && $0.targetUid == targetUid }
    }

    private func listenToRequests(_ filter: @escaping @Sendable (AlertRequestDocument) -> Bool) -> AsyncThrowingStream<[AlertRequestDocument], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [AlertRequestDocument].self)
        let current = state.withLock { state in
            state.requestListeners.append((filter, continuation))
            return Array(state.requests.values)
        }
        continuation.yield(current.filter(filter))
        return stream
    }

    private func updateRequests(_ change: (inout [String: AlertRequestDocument]) -> Void) {
        let (requests, listeners) = state.withLock { state in
            change(&state.requests)
            return (Array(state.requests.values), state.requestListeners)
        }
        for listener in listeners {
            listener.continuation.yield(requests.filter(listener.filter))
        }
    }

    func createAlertRequest(_ document: AlertRequestDocument) async throws {
        var stored = document
        stored.createdAt = .now
        updateRequests { $0[document.id] = stored }
    }

    func deleteAlertRequest(id: String, on targetUid: String) async throws {
        updateRequests { $0[id] = nil }
    }

    func alertPreferences(of uid: String) -> AsyncThrowingStream<AlertPreferences, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AlertPreferences.self)
        let current = state.withLock { state in
            state.preferenceListeners[uid, default: []].append(continuation)
            return state.preferences[uid] ?? AlertPreferences()
        }
        continuation.yield(current)
        return stream
    }

    func fetchAlertPreferences(of uid: String) async throws -> AlertPreferences {
        state.withLock { $0.preferences[uid] ?? AlertPreferences() }
    }

    func saveAlertPreferences(_ preferences: AlertPreferences, for uid: String) async throws {
        let listeners = state.withLock { state in
            state.preferences[uid] = preferences
            return state.preferenceListeners[uid] ?? []
        }
        listeners.forEach { $0.yield(preferences) }
    }

    func postNotificationEvent(from fromUid: String, to toUid: String, payload: SealedBox, expiresAt: Date) async throws {
        state.withLock { $0.events.append((fromUid, toUid)) }
    }
}

/// Region monitoring without Core Location. Tests send events by hand.
actor InMemoryGeofences: GeofenceMonitoring {
    private(set) var alerts: [String: MonitoredAlert] = [:]
    private var continuations: [AsyncStream<GeofenceEvent>.Continuation] = []

    func monitoredIDs() async -> Set<String> {
        Set(alerts.keys)
    }

    func add(_ alert: MonitoredAlert) async {
        alerts[alert.id] = alert
    }

    func remove(_ id: String) async {
        alerts[id] = nil
    }

    func events() async -> AsyncStream<GeofenceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: GeofenceEvent.self)
        continuations.append(continuation)
        return stream
    }

    var listenerCount: Int {
        continuations.count
    }

    func send(_ event: GeofenceEvent) {
        continuations.forEach { $0.yield(event) }
    }
}

/// Background location that never reports anything.
@MainActor
final class NoBackgroundLocation: BackgroundLocationProviding {
    var onLocation: ((UserLocation) -> Void)?
    var isAlwaysAuthorized = false
    var isAccuracyReduced = false
    private(set) var isMonitoring = false

    func startSignificantChanges() {
        isMonitoring = true
    }

    func stopSignificantChanges() {
        isMonitoring = false
    }

    func requestLocation() async throws -> UserLocation {
        throw CancellationError()
    }
}

struct FixedAddressLookup: AddressLookup {
    let address: String?

    func address(latitude: Double, longitude: Double) async throws -> String? {
        address
    }
}
#endif
