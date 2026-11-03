//
//  FirebaseBootstrap.swift
//  WAYFirebase
//

import DeviceCheck
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OSLog

/// Which Firebase the app and its extensions talk to.
///
/// Forks add their own GoogleService-Info.plist to the app's where-are-you folder (it's
/// gitignored). Debug builds without one use the local emulators, so the app runs straight
/// from a clone.
public enum BackendConfiguration: Equatable, Sendable {
    case firebase(FirebaseBootstrap.Mode)
    /// A Release build without GoogleService-Info.plist. The app shows setup instructions.
    case missing

    /// "1" forces the emulators in Debug builds even when GoogleService-Info.plist exists.
    public static let useEmulatorKey = "USE_FIREBASE_EMULATOR"
    /// Emulator host, e.g. your Mac's LAN address when running on a device. Defaults to 127.0.0.1.
    public static let emulatorHostKey = "FIREBASE_EMULATOR_HOST"
    public static let configFileName = "GoogleService-Info"

    /// - Parameter isDebugBuild: Pass `true` from `#if DEBUG` code; only Debug builds may use
    ///   the emulators.
    public static func resolve(configFile: URL?, environment: [String: String], isDebugBuild: Bool) -> BackendConfiguration {
        if isDebugBuild, environment[useEmulatorKey] == "1" || configFile == nil {
            return .firebase(.emulator(host: environment[emulatorHostKey] ?? "127.0.0.1"))
        }
        return configFile.map { .firebase(.project(configFile: $0)) } ?? .missing
    }

    /// The config file in `bundle`, if the developer added one.
    public static func configFile(in bundle: Bundle) -> URL? {
        bundle.url(forResource: configFileName, withExtension: "plist")
    }

    /// Extensions use the containing app's config file, so forks only add it once.
    public static func containingAppConfigFile(forExtension bundle: Bundle = .main) -> URL? {
        // MyApp.app/PlugIns/MyExtension.appex
        let appURL = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: appURL).flatMap(configFile(in:))
    }
}

public enum FirebaseBootstrap {
    public enum Mode: Sendable, Equatable {
        /// A real Firebase project, configured from a GoogleService-Info.plist.
        case project(configFile: URL)
        /// The local Firebase emulators (`firebase emulators:start` in firebase/). Needs no project.
        case emulator(host: String)
    }

    public enum ConfigurationError: Error {
        case unreadableConfigFile
    }

    /// Must match `.firebaserc`. The `demo-` prefix tells the emulators there's no real project.
    public static let emulatorProjectID = "demo-where-are-you"

    /// Call at launch, before any other Firebase use. Calling again does nothing.
    ///
    /// `keychainAccessGroup` shares the signed-in user between the app and its extensions. It
    /// needs the matching Keychain Sharing entitlement.
    @MainActor
    public static func configure(mode: Mode, keychainAccessGroup: String?) throws {
        guard FirebaseApp.app() == nil else { return }

        switch mode {
        case .project(let configFile):
            guard let options = FirebaseOptions(contentsOfFile: configFile.path) else {
                throw ConfigurationError.unreadableConfigFile
            }
            AppCheck.setAppCheckProviderFactory(AppCheckProviders())
            FirebaseApp.configure(options: options)

        case .emulator(let host):
            // The emulators accept any app ID and API key. App Check isn't enforced there.
            let options = FirebaseOptions(googleAppID: "1:000000000000:ios:0000000000000000", gcmSenderID: "000000000000")
            options.projectID = emulatorProjectID
            options.apiKey = "emulator-api-key"
            options.bundleID = Bundle.main.bundleIdentifier ?? ""
            FirebaseApp.configure(options: options)

            Auth.auth().useEmulator(withHost: host, port: 9099)
            let settings = Firestore.firestore().settings
            settings.host = "\(host):8080"
            settings.isSSLEnabled = false
            settings.cacheSettings = MemoryCacheSettings()
            Firestore.firestore().settings = settings
            Functions.functions().useEmulator(withHost: host, port: 5001)
            Log.firebase.notice("Using Firebase emulators at \(host, privacy: .public)")
        }

        if let keychainAccessGroup {
            do {
                try Auth.auth().useUserAccessGroup(keychainAccessGroup)
            } catch {
                // The app still works; only its extensions lose the shared sign-in.
                Log.firebase.error("Sharing sign-in with extensions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// App Attest where the device supports it (not every device or extension does), DeviceCheck
/// otherwise, and the debug provider in the simulator (register its printed token in the console).
private final class AppCheckProviders: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        if DCAppAttestService.shared.isSupported, let provider = AppAttestProvider(app: app) {
            return provider
        }
        return DeviceCheckProvider(app: app)
        #endif
    }
}

enum Log {
    static let firebase = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WAYFirebase", category: "firebase")
}
