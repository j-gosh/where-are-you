//
//  SessionModel.swift
//  where-are-you
//

import Foundation
import Observation
import OSLog
import WAYCore

/// Sign-in, the identity key, and the user's own profile. Drives which screen the app shows.
///
/// After sign-in, setup makes sure this device holds the private key matching the published
/// public key, then decrypts the user's profile (sealed to their own key).
@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable {
        /// Waiting for the first auth state.
        case loading
        case signedOut
        /// Checking keys and loading the profile.
        case settingUp
        /// The account has a published key this device doesn't hold (yet).
        case keyMissing
        case needsProfile
        case ready
        /// Setup failed, usually for lack of network. The message is user-facing.
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Set while `phase` is `.ready`.
    private(set) var account: Account?
    /// From Sign in with Apple, offered when creating a profile.
    private(set) var suggestedName: String?
    /// True while a user-initiated action (sign-in, save, delete) runs.
    private(set) var isWorking = false
    /// The last failed user action, for an alert. Views clear it when dismissed.
    var actionError: String?

    let isUsingEmulator: Bool
    /// Told about every change to `account`, so services can start or stop.
    @ObservationIgnored var onAccountChange: ((Account?) -> Void)?
    /// Runs before signing out, while the account can still write (e.g. to unregister pushes).
    @ObservationIgnored var willSignOut: ((String) async -> Void)?

    @ObservationIgnored private let auth: AuthBackend
    @ObservationIgnored private let accountBackend: AccountBackend
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let reauthenticator: AppleReauthenticator
    @ObservationIgnored private var currentUID: String?
    /// The identity key for `currentUID`, once setup has found or created it.
    @ObservationIgnored private var identity: IdentityKey?
    @ObservationIgnored private var setUpTask: Task<Void, Never>?

    init(auth: AuthBackend, account: AccountBackend, keyStore: KeyStore, reauthenticator: AppleReauthenticator, isUsingEmulator: Bool) {
        self.auth = auth
        self.accountBackend = account
        self.keyStore = keyStore
        self.reauthenticator = reauthenticator
        self.isUsingEmulator = isUsingEmulator
    }

    /// Follows auth state until the calling task is cancelled. Call from the root view's `.task`.
    func run() async {
        for await uid in auth.userIDs() {
            userDidChange(to: uid)
        }
    }

    // MARK: Setup

    private func userDidChange(to uid: String?) {
        if uid == currentUID, phase != .loading {
            return
        }
        setUpTask?.cancel()
        currentUID = uid
        identity = nil
        setAccount(nil)
        guard let uid else {
            phase = .signedOut
            return
        }
        startSetUp(uid: uid)
    }

    func retry() {
        guard let uid = currentUID else { return }
        setUpTask?.cancel()
        startSetUp(uid: uid)
    }

    private func startSetUp(uid: String) {
        phase = .settingUp
        setUpTask = Task { await setUp(uid: uid) }
    }

    private func setUp(uid: String) async {
        do {
            guard let identity = try await resolveIdentity(uid: uid) else {
                if isCurrent(uid) { phase = .keyMissing }
                return
            }
            let profile = try await loadProfile(uid: uid, identity: identity)
            guard isCurrent(uid) else { return }
            self.identity = identity
            if let profile {
                setAccount(Account(uid: uid, identity: identity, profile: profile))
                phase = .ready
            } else {
                phase = .needsProfile
            }
        } catch {
            guard isCurrent(uid) else { return }
            Logger.session.error("Account setup failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(String(localized: "Couldn't set up your account. Check your connection and try again."))
        }
    }

    /// The key to use, or `nil` when the published key isn't on this device.
    private func resolveIdentity(uid: String) async throws -> IdentityKey? {
        let local = try keyStore.identityKey(for: uid)
        let published = try await accountBackend.publicIdentity(of: uid)
        switch (local, published) {
        case (nil, nil):
            // New account: create and publish a key.
            let key = IdentityKey.generate()
            try keyStore.save(key, for: uid)
            try await accountBackend.publishIdentity(key.publicIdentity, for: uid)
            return key
        case (let local?, nil):
            // A previous attempt saved the key but didn't finish publishing it.
            try await accountBackend.publishIdentity(local.publicIdentity, for: uid)
            return local
        case (let local?, let published?) where local.publicIdentity == published:
            return local
        default:
            // Either iCloud Keychain hasn't synced the key here yet, or another device replaced
            // it. Never overwrite the published key without the user asking.
            return nil
        }
    }

    private func loadProfile(uid: String, identity: IdentityKey) async throws -> Profile? {
        guard let box = try await accountBackend.ownProfileBox(for: uid) else { return nil }
        do {
            return try Sealing.open(Profile.self, from: box, sender: identity.publicIdentity, senderUid: uid, recipient: identity, recipientUid: uid)
        } catch {
            // Sealed with a key this account no longer uses (after a key reset): ask again.
            Logger.session.notice("Own profile can't be decrypted with the current key: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func setAccount(_ newAccount: Account?) {
        guard account?.uid != newAccount?.uid || account?.profile != newAccount?.profile else { return }
        account = newAccount
        onAccountChange?(newAccount)
    }

    private func isCurrent(_ uid: String) -> Bool {
        uid == currentUID && !Task.isCancelled
    }

    // MARK: Actions

    func signIn(with credential: AppleCredential) async {
        suggestedName = credential.fullName
            .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            .flatMap { $0.isEmpty ? nil : $0 }
        await perform(failureMessage: String(localized: "Couldn't sign in.")) {
            _ = try await auth.signIn(with: credential)
        }
    }

    func reportSignInFailure(_ error: Error) {
        Logger.session.error("Sign in with Apple failed: \(error.localizedDescription, privacy: .public)")
        actionError = String(localized: "Sign in with Apple didn't work. Please try again.")
    }

    /// Creates or updates the profile, sealed to the user's own key. Returns whether it saved.
    @discardableResult
    func saveProfile(_ profile: Profile) async -> Bool {
        guard let uid = currentUID, let identity else { return false }
        var saved = false
        await perform(failureMessage: String(localized: "Couldn't save your profile.")) {
            let box = try Sealing.seal(profile, from: identity, senderUid: uid, to: identity.publicIdentity, recipientUid: uid)
            try await accountBackend.saveOwnProfileBox(box, for: uid)
            guard uid == currentUID else { return }
            setAccount(Account(uid: uid, identity: identity, profile: profile))
            suggestedName = nil
            phase = .ready
            saved = true
        }
        return saved
    }

    /// Replaces the account's key with a new one from this device. Anything sealed to the old
    /// key, including the user's profile, becomes unreadable.
    func resetKey() async {
        guard let uid = currentUID, phase == .keyMissing else { return }
        await perform(failureMessage: String(localized: "Couldn't create a new key.")) {
            let key = IdentityKey.generate()
            try keyStore.save(key, for: uid)
            try await accountBackend.publishIdentity(key.publicIdentity, for: uid)
            guard uid == currentUID else { return }
            identity = key
            phase = .needsProfile
        }
    }

    func signOut() async {
        if let uid = currentUID {
            await willSignOut?(uid)
        }
        do {
            try auth.signOut()
        } catch {
            Logger.session.error("Sign out failed: \(error.localizedDescription, privacy: .public)")
            actionError = String(localized: "Couldn't sign out. Please try again.")
        }
    }

    /// Re-authenticates with Apple, revokes the app's Apple token, deletes all server data and
    /// the account, then removes the key from this device and signs out.
    func deleteAccount() async {
        guard let uid = currentUID else { return }
        var deleted = false
        await perform(failureMessage: String(localized: "Couldn't delete your account.")) {
            // The emulators can't verify Apple tokens, so there's nothing to revoke there.
            if !isUsingEmulator {
                let credential = try await reauthenticator.requestCredential()
                try await auth.reauthenticate(with: credential)
                guard let code = credential.authorizationCode else {
                    throw SessionError.missingAuthorizationCode
                }
                try await auth.revokeAppleToken(authorizationCode: code)
            }
            try await accountBackend.deleteAccount()
            deleted = true
        }
        guard deleted else { return }

        // The server side is gone; local cleanup failures can only be logged.
        do {
            try keyStore.deleteIdentityKey(for: uid)
        } catch {
            Logger.session.error("Removing the deleted account's key failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try auth.signOut()
        } catch {
            Logger.session.error("Sign out after deletion failed: \(error.localizedDescription, privacy: .public)")
        }
        userDidChange(to: nil)
    }

    /// Runs a user action with `isWorking` set. User cancellation is silent; other errors set
    /// `actionError`.
    private func perform(failureMessage: String, _ action: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            Logger.session.error("\(failureMessage, privacy: .public) \(error.localizedDescription, privacy: .public)")
            actionError = "\(failureMessage) \(error.localizedDescription)"
        }
    }
}

enum SessionError: LocalizedError {
    case missingAuthorizationCode

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationCode:
            String(localized: "Apple didn't return the code needed to finish deleting your account.")
        }
    }
}

#if DEBUG
extension SessionModel {
    /// Signs in to the Auth emulator, which accepts an unsigned JSON "ID token" for any provider.
    func signInWithEmulatorTestAccount(named name: String) async {
        let handle = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let claims: [String: Any] = [
            "sub": "test-\(handle)",
            "email": "\(handle)@example.com",
            "email_verified": true,
        ]
        guard isUsingEmulator,
              !handle.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: claims),
              let token = String(data: data, encoding: .utf8) else { return }
        var fullName = PersonNameComponents()
        fullName.givenName = name
        await signIn(with: AppleCredential(idToken: token, rawNonce: nil, authorizationCode: nil, fullName: fullName))
    }
}
#endif
