//
//  AppDependencies.swift
//  where-are-you
//

import Foundation
import OSLog
import SwiftUI
import WAYCore
import WAYFirebase

/// The services the app runs with. `make()` picks real ones, or fakes when tests ask for them.
@MainActor
struct AppDependencies {
    /// `nil` when the build has no backend configuration (see `BackendConfiguration`); so are
    /// the services below that need a backend.
    let session: SessionModel?
    let locationService: LocationService
    let addressLookup: any AddressLookup
    /// Builds the friends repository once an account is signed in and set up.
    let makeFriendsRepository: @MainActor (Account) -> any FriendsRepository
    let sharing: SharingService?
    let alerts: AlertService?
    let push: PushService?

    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppDependencies {
        #if DEBUG
        if environment[LaunchEnvironment.fakeServices] == "1" {
            return .fake(environment: environment)
        }
        // Unit tests host the app; keep Firebase and real location out of them.
        if environment["XCTestConfigurationFilePath"] != nil {
            return .fake(environment: [:])
        }
        #endif
        return .live(environment: environment)
    }

    static func live(environment: [String: String]) -> AppDependencies {
        let locationService = LocationService(provider: CoreLocationProvider())
        let keychainGroup = sharedKeychainGroup()
        guard let mode = configureFirebase(environment: environment, keychainGroup: keychainGroup) else {
            return AppDependencies(
                session: nil,
                locationService: locationService,
                addressLookup: GeocoderAddressLookup(),
                makeFriendsRepository: { _ in FixtureFriendsRepository(friends: []) },
                sharing: nil,
                alerts: nil,
                push: nil
            )
        }

        let auth = FirebaseAuthBackend()
        let accounts = FirebaseAccountBackend()
        let friends = FirebaseFriendsBackend()
        let keyStore = KeychainKeyStore(accessGroup: keychainGroup)
        let deviceId = DeviceIdentity.current()
        let accountProvider = AccountProvider(auth: auth, accounts: accounts, keyStore: keyStore)
        let isUsingEmulator = if case .emulator = mode { true } else { false }

        return wire(
            session: SessionModel(auth: auth, account: accounts, keyStore: keyStore, reauthenticator: SystemAppleReauthenticator(), isUsingEmulator: isUsingEmulator),
            accountProvider: accountProvider,
            locationService: locationService,
            addressLookup: GeocoderAddressLookup(),
            makeFriendsRepository: { account in
                LiveFriendsRepository(
                    account: account,
                    backend: friends,
                    accounts: accounts,
                    pins: KeychainPinnedKeyStore(accessGroup: keychainGroup),
                    directory: KeychainFriendDirectoryStore(accessGroup: keychainGroup)
                )
            },
            sharing: SharingService(
                accountProvider: accountProvider,
                backend: FirebaseSharingBackend(),
                friends: friends,
                accounts: accounts,
                background: SignificantChangeMonitor(),
                deviceId: deviceId
            ),
            alerts: AlertService(accountProvider: accountProvider, backend: FirebaseAlertsBackend(), accounts: accounts, geofences: CoreLocationGeofences.shared),
            // Pushes need a real project; the emulators don't deliver them.
            push: PushService(registrar: isUsingEmulator ? nil : FirebasePushBackend(), deviceId: deviceId, accountProvider: accountProvider)
        )
    }

    /// Connects the session to the account-scoped services, and location readings to sharing.
    static func wire(
        session: SessionModel,
        accountProvider: AccountProvider,
        locationService: LocationService,
        addressLookup: any AddressLookup,
        makeFriendsRepository: @escaping @MainActor (Account) -> any FriendsRepository,
        sharing: SharingService,
        alerts: AlertService,
        push: PushService
    ) -> AppDependencies {
        session.onAccountChange = { [accountProvider] account in
            accountProvider.set(account)
        }
        session.willSignOut = { [push] uid in
            await push.unregister(uid: uid)
        }
        locationService.onLocation = { [weak sharing] location, isApproximate in
            Task { await sharing?.handleForeground(location, isApproximate: isApproximate) }
        }
        sharing.currentLocation = { [weak locationService] in
            guard let locationService, let location = locationService.userLocation else { return nil }
            return (location, locationService.isAccuracyReduced)
        }
        return AppDependencies(
            session: session,
            locationService: locationService,
            addressLookup: addressLookup,
            makeFriendsRepository: makeFriendsRepository,
            sharing: sharing,
            alerts: alerts,
            push: push
        )
    }

    /// From Config/App-Info.plist. `nil` if the build setting didn't expand.
    static func sharedKeychainGroup(in bundle: Bundle = .main) -> String? {
        (bundle.object(forInfoDictionaryKey: "WAYKeychainAccessGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func configureFirebase(environment: [String: String], keychainGroup: String?) -> FirebaseBootstrap.Mode? {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let configuration = BackendConfiguration.resolve(
            configFile: BackendConfiguration.configFile(in: .main),
            environment: environment,
            isDebugBuild: isDebugBuild
        )
        guard case .firebase(let mode) = configuration else { return nil }
        do {
            try FirebaseBootstrap.configure(mode: mode, keychainAccessGroup: keychainGroup)
            return mode
        } catch {
            Logger.session.fault("Firebase configuration failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

extension FirebasePushBackend: PushRegistering {}

/// A stable ID for this installation: which device shares the location, and where pushes go.
enum DeviceIdentity {
    private static let key = "deviceId"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key) {
            return id
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}

extension View {
    /// Puts the app-wide services into the environment.
    func dependencies(_ dependencies: AppDependencies) -> some View {
        environment(dependencies.session)
            .environment(dependencies.locationService)
            .environment(\.addressLookup, dependencies.addressLookup)
            .environment(dependencies.sharing)
            .environment(dependencies.alerts)
            .environment(dependencies.push)
    }
}
