//
//  AccountProvider.swift
//  where-are-you
//

import Foundation
import UIKit
import WAYCore

/// The signed-in account for services that also run without any UI: location sharing and
/// alerts, after iOS relaunches the app in the background for a location or region event.
@MainActor
final class AccountProvider {
    /// Set by `SessionModel` once setup finishes; `nil` when signed out.
    private(set) var account: Account?
    private var observers: [(Account?) -> Void] = []

    private let auth: AuthBackend
    private let accounts: AccountBackend
    private let keyStore: KeyStore

    init(auth: AuthBackend, accounts: AccountBackend, keyStore: KeyStore) {
        self.auth = auth
        self.accounts = accounts
        self.keyStore = keyStore
    }

    /// Calls `observer` now and whenever the session's account changes.
    func observe(_ observer: @escaping (Account?) -> Void) {
        observers.append(observer)
        observer(account)
    }

    func set(_ account: Account?) {
        self.account = account
        for observer in observers {
            observer(account)
        }
    }

    /// The account, loading it directly when no UI has run yet (a background launch). Doesn't
    /// notify observers: those start listeners meant for the foreground.
    func load() async throws -> Account? {
        if let account {
            return account
        }
        guard let uid = await firstValue(of: auth.userIDs()) ?? nil else { return nil }
        return try await AccountLoader.loadExisting(uid: uid, keyStore: keyStore, accounts: accounts)
    }
}

/// The first element of a stream, or `nil` if it ends first.
func firstValue<Values: AsyncSequence>(of values: Values) async rethrows -> Values.Element? {
    for try await value in values {
        return value
    }
    return nil
}

/// Asks iOS for extra time to finish work that started in the background.
@MainActor
struct BackgroundTask {
    private let identifier: UIBackgroundTaskIdentifier

    static func begin(_ name: String) -> BackgroundTask {
        BackgroundTask(identifier: UIApplication.shared.beginBackgroundTask(withName: name))
    }

    func end() {
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
