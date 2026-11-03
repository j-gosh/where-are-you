//
//  ConfigurationTests.swift
//  where-are-youTests
//

import Foundation
import Testing
import WAYCore
import WAYFirebase
@testable import where_are_you

struct BackendConfigurationTests {
    private let configFile = URL(fileURLWithPath: "/tmp/GoogleService-Info.plist")

    @Test func debugWithoutConfigFileUsesLocalEmulators() {
        #expect(BackendConfiguration.resolve(configFile: nil, environment: [:], isDebugBuild: true) == .firebase(.emulator(host: "127.0.0.1")))
    }

    @Test func configFileSelectsTheRealProject() {
        #expect(BackendConfiguration.resolve(configFile: configFile, environment: [:], isDebugBuild: true) == .firebase(.project(configFile: configFile)))
    }

    @Test func environmentCanForceEmulatorsAndPickHost() {
        let environment = [BackendConfiguration.useEmulatorKey: "1", BackendConfiguration.emulatorHostKey: "192.168.1.20"]
        #expect(BackendConfiguration.resolve(configFile: configFile, environment: environment, isDebugBuild: true) == .firebase(.emulator(host: "192.168.1.20")))
    }

    @Test func releaseBuildsNeverUseEmulators() {
        let environment = [BackendConfiguration.useEmulatorKey: "1"]
        #expect(BackendConfiguration.resolve(configFile: nil, environment: environment, isDebugBuild: false) == .missing)
        #expect(BackendConfiguration.resolve(configFile: configFile, environment: environment, isDebugBuild: false) == .firebase(.project(configFile: configFile)))
    }
}

struct AppleSignInTests {
    @Test func noncesAreRandomAndURLSafe() {
        let nonces = (0..<10).map { _ in AppleSignIn.makeNonce() }
        #expect(Set(nonces).count == nonces.count)
        #expect(nonces.allSatisfy { $0.count == 43 && Data(base64URLEncoded: $0) != nil })
    }

    @Test func hashesNonceAsLowercaseHexSHA256() {
        #expect(AppleSignIn.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// The real app's shared access group, which needs the Keychain Sharing entitlement to work.
struct SharedKeychainGroupTests {
    @Test func appDeclaresSharedGroupAndCanUseIt() throws {
        let group = try #require(Bundle.main.object(forInfoDictionaryKey: "WAYKeychainAccessGroup") as? String)
        #expect(group.hasSuffix(".where-are-you.shared"))

        let store = KeychainKeyStore(service: "WhereAreYou.Tests.\(UUID().uuidString)", accessGroup: group)
        defer { try? store.deleteIdentityKey(for: "alice") }
        let key = try store.loadOrCreateIdentityKey(for: "alice").key
        #expect(try store.identityKey(for: "alice")?.publicIdentity == key.publicIdentity)
    }
}

@MainActor
struct KeychainPinnedKeyStoreTests {
    @Test func pinsPersistPerAccountInSharedGroup() throws {
        let group = AppDependencies.sharedKeychainGroup()
        let store = KeychainPinnedKeyStore(service: "WhereAreYou.Tests.\(UUID().uuidString)", accessGroup: group)
        let pin = PinnedKey(keyId: "key", trust: .compared)
        defer { try? store.setPin(nil, forFriend: "olivia", account: "me") }

        try store.setPin(pin, forFriend: "olivia", account: "me")

        #expect(try store.pins(for: "me") == ["olivia": pin])
        #expect(try store.pins(for: "someone-else").isEmpty)
    }
}
