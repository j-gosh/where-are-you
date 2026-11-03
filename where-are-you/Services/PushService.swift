//
//  PushService.swift
//  where-are-you
//

import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications
import WAYCore

/// Registers this device for pushes so alerts reach it. Implemented by WAYFirebase's
/// `FirebasePushBackend`.
protocol PushRegistering: Sendable {
    @MainActor func setAPNSToken(_ token: Data)
    func registrationToken() async throws -> String
    func tokenRefreshes() -> AsyncStream<Void>
    func saveDeviceToken(_ token: String, deviceId: String, for uid: String) async throws
    func deleteDeviceToken(deviceId: String, for uid: String) async throws
}

/// Notification permission and push registration.
@MainActor
@Observable
final class PushService {
    enum Permission: Equatable {
        case notDetermined
        case denied
        case allowed
    }

    private(set) var permission: Permission = .notDetermined

    @ObservationIgnored private let registrar: PushRegistering?
    @ObservationIgnored private let deviceId: String
    @ObservationIgnored private var account: Account?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// - Parameter registrar: `nil` when pushes can't work, e.g. with the emulators.
    init(registrar: PushRegistering?, deviceId: String, accountProvider: AccountProvider) {
        self.registrar = registrar
        self.deviceId = deviceId
        accountProvider.observe { [weak self] account in
            self?.setAccount(account)
        }
        Task { await refreshPermission() }
    }

    private func setAccount(_ account: Account?) {
        self.account = account
        refreshTask?.cancel()
        guard account != nil, let registrar else { return }
        if permission == .allowed {
            UIApplication.shared.registerForRemoteNotifications()
        }
        refreshTask = Task { [weak self] in
            for await _ in registrar.tokenRefreshes() {
                await self?.saveToken()
            }
        }
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permission = switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    /// Shows the system prompt the first time; afterwards the user has to use Settings.
    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if granted, registrar != nil {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            Logger.alerts.error("Requesting notification permission failed: \(error.localizedDescription, privacy: .public)")
        }
        await refreshPermission()
    }

    /// From the app delegate.
    func didRegister(deviceToken: Data) {
        guard let registrar else { return }
        registrar.setAPNSToken(deviceToken)
        Task { await saveToken() }
    }

    private func saveToken() async {
        guard let account, let registrar else { return }
        do {
            let token = try await registrar.registrationToken()
            try await registrar.saveDeviceToken(token, deviceId: deviceId, for: account.uid)
        } catch {
            Logger.alerts.error("Registering for pushes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Before signing out, so this device stops getting the account's alerts.
    func unregister(uid: String) async {
        guard let registrar else { return }
        do {
            try await registrar.deleteDeviceToken(deviceId: deviceId, for: uid)
        } catch {
            Logger.alerts.error("Unregistering from pushes failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
