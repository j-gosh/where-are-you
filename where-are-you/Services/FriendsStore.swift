//
//  FriendsStore.swift
//  where-are-you
//

import Foundation
import Observation
import OSLog
import WAYCore

/// The friend list shown on the map and in the People sheet, for the signed-in account.
@MainActor
@Observable
final class FriendsStore {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    /// Sorted by display name.
    private(set) var friends: [Friend] = []
    private(set) var loadState: LoadState = .loading
    /// Changes when the user asks to retry; views restart `observe()` with `.task(id:)`.
    private(set) var reloadToken = 0

    @ObservationIgnored private let repository: any FriendsRepository

    init(repository: any FriendsRepository) {
        self.repository = repository
    }

    func friend(id: Friend.ID) -> Friend? {
        friends.first { $0.id == id }
    }

    /// Applies friend updates until the calling task is cancelled.
    func observe() async {
        if loadState == .failed {
            loadState = .loading
        }
        do {
            for try await friends in repository.friends() {
                self.friends = friends.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                loadState = .loaded
            }
            if loadState == .loading {
                loadState = .loaded
            }
        } catch {
            Logger.friends.error("Loading friends failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed
        }
    }

    func retry() {
        reloadToken += 1
    }

    // MARK: Actions. Callers show the errors.

    func createInvite() async throws -> InviteLink {
        try await repository.createInvite()
    }

    func acceptInvite(_ link: InviteLink) async throws {
        try await repository.acceptInvite(link)
    }

    func removeFriend(_ id: Friend.ID) async throws {
        try await repository.removeFriend(id)
    }

    func markKeyVerified(_ id: Friend.ID) throws {
        try repository.markKeyVerified(id)
    }

    func acceptKeyChange(_ id: Friend.ID) throws {
        try repository.acceptKeyChange(id)
    }

    func shareProfile(_ profile: Profile) async {
        await repository.shareProfile(profile)
    }
}
