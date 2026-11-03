//
//  MessagesModel.swift
//  WhereAreYouMessages
//

import Foundation
import Messages
import Observation
import OSLog
import WAYCore
import WAYFirebase

/// Sends invite bubbles and accepts them, using the account the app already set up. Signing
/// in and creating keys or profiles only happens in the app.
@MainActor
@Observable
final class MessagesModel {
    enum State: Equatable {
        case loading
        case signedOut
        /// Signed in, but this device lacks the key or there's no profile yet.
        case needsSetup
        case ready
        case failed(String)
    }

    enum AcceptStatus: Equatable {
        case idle
        case accepting
        case accepted
        case failed(String)
    }

    enum Failure: LocalizedError {
        case noConversation

        var errorDescription: String? {
            String(localized: "Open a conversation to send an invite.")
        }
    }

    private(set) var state: State = .loading
    /// The invite in the bubble the user tapped, if any.
    private(set) var selectedInvite: InviteLink?
    private(set) var acceptStatus: AcceptStatus = .idle
    private(set) var isSending = false
    var errorMessage: String?

    /// Set by the view controller.
    @ObservationIgnored var openURL: (URL) -> Void = { _ in }
    @ObservationIgnored var insertMessage: @MainActor (MSMessage) async throws -> Void = { _ in }

    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var services: Services?

    private struct Services {
        let auth: AuthBackend
        let accounts: AccountBackend
        let friends: FriendsBackend
        let keyStore: KeyStore
        let pins: PinnedKeyStore

        var inviteFlow: InviteFlow {
            InviteFlow(friends: friends, accounts: accounts, pins: pins)
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WhereAreYouMessages", category: "messages")

    var isOwnInvite: Bool {
        guard let selectedInvite, let account else { return false }
        return selectedInvite.inviterKeyId == account.identity.publicIdentity.keyId
    }

    func load() async {
        state = .loading
        guard let services = services ?? makeServices() else {
            state = .failed(String(localized: "Where Are You isn't configured. Open the app for details."))
            return
        }
        self.services = services
        do {
            guard let uid = await firstUserID(from: services.auth) else {
                state = .signedOut
                return
            }
            guard let account = try await AccountLoader.loadExisting(uid: uid, keyStore: services.keyStore, accounts: services.accounts) else {
                state = .needsSetup
                return
            }
            self.account = account
            state = .ready
        } catch {
            Self.logger.error("Loading the account failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(localized: "Couldn't connect. Check your connection and try again."))
        }
    }

    func show(selectedMessage: MSMessage?) {
        selectedInvite = selectedMessage?.url.flatMap { try? InviteLink(url: $0) }
        acceptStatus = .idle
    }

    func sendInvite() async {
        guard let account, let services else { return }
        isSending = true
        defer { isSending = false }
        do {
            let link = try await services.inviteFlow.createInvite(for: account)
            let message = try InviteMessage.make(for: link, landingURL: InviteMessage.landingURL())
            try await insertMessage(message)
        } catch {
            Self.logger.error("Sending an invite failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func acceptSelectedInvite() async {
        guard let link = selectedInvite, let account, let services else { return }
        acceptStatus = .accepting
        do {
            _ = try await services.inviteFlow.accept(link, as: account)
            acceptStatus = .accepted
        } catch {
            Self.logger.error("Accepting an invite failed: \(error.localizedDescription, privacy: .public)")
            acceptStatus = .failed(error.localizedDescription)
        }
    }

    /// Opens the app, handing it the selected invite so it can accept after signing in.
    func openApp() {
        let url = selectedInvite.flatMap { try? $0.url(base: InviteMessage.appURL) } ?? InviteMessage.appURL
        openURL(url)
    }

    private func firstUserID(from auth: AuthBackend) async -> String? {
        for await uid in auth.userIDs() {
            return uid
        }
        return nil
    }

    private func makeServices() -> Services? {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let configuration = BackendConfiguration.resolve(
            configFile: BackendConfiguration.containingAppConfigFile(),
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild
        )
        guard case .firebase(let mode) = configuration else { return nil }
        let keychainGroup = (Bundle.main.object(forInfoDictionaryKey: "WAYKeychainAccessGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        do {
            try FirebaseBootstrap.configure(mode: mode, keychainAccessGroup: keychainGroup)
        } catch {
            Self.logger.fault("Firebase configuration failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return Services(
            auth: FirebaseAuthBackend(),
            accounts: FirebaseAccountBackend(),
            friends: FirebaseFriendsBackend(),
            keyStore: KeychainKeyStore(accessGroup: keychainGroup),
            pins: KeychainPinnedKeyStore(accessGroup: keychainGroup)
        )
    }
}
