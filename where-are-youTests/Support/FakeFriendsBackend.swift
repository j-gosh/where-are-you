//
//  FakeFriendsBackend.swift
//  where-are-youTests
//

import Foundation
import Synchronization
import WAYCore

/// A friends backend whose listeners tests drive by hand.
final class FakeFriendsBackend: FriendsBackend {
    private struct State {
        var friendListeners: [AsyncThrowingStream<Set<String>, Error>.Continuation] = []
        var shareListeners: [AsyncThrowingStream<[ShareDocument], Error>.Continuation] = []
        /// recipient → sender → share the signed-in user published.
        var published: [String: [String: ShareDocument]] = [:]
        var removedFriends: [String] = []
    }

    private let state = Mutex(State())

    var publishedShares: [String: [String: ShareDocument]] { state.withLock { $0.published } }
    var removedFriends: [String] { state.withLock { $0.removedFriends } }
    var hasFriendListener: Bool { state.withLock { !$0.friendListeners.isEmpty } }
    /// True once something listens to both friendships and shares.
    var isListening: Bool { state.withLock { !$0.friendListeners.isEmpty && !$0.shareListeners.isEmpty } }

    func sendFriends(_ uids: Set<String>) {
        for listener in state.withLock({ $0.friendListeners }) {
            listener.yield(uids)
        }
    }

    func sendShares(_ shares: [ShareDocument]) {
        for listener in state.withLock({ $0.shareListeners }) {
            listener.yield(shares)
        }
    }

    func friendUIDs(of uid: String) -> AsyncThrowingStream<Set<String>, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Set<String>.self)
        state.withLock { $0.friendListeners.append(continuation) }
        return stream
    }

    func incomingShares(for uid: String) -> AsyncThrowingStream<[ShareDocument], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [ShareDocument].self)
        state.withLock { $0.shareListeners.append(continuation) }
        return stream
    }

    func outgoingShare(from uid: String, to friendUid: String) async throws -> ShareDocument? {
        state.withLock { $0.published[friendUid]?[uid] }
    }

    func publishProfile(_ box: SealedBox, from uid: String, to friendUid: String) async throws {
        state.withLock {
            $0.published[friendUid, default: [:]][uid] = ShareDocument(senderUid: uid, profile: box, location: nil, isSharingLocation: false)
        }
    }

    func createInvite(token: String, inviterUid: String, inviterKeyId: String, expiresAt: Date) async throws {}

    func invite(token: String) async throws -> InviteDocument? {
        nil
    }

    func acceptInvite(token: String) async throws -> String {
        throw InviteError.expiredOrUsed
    }

    func removeFriend(_ friendUid: String) async throws {
        state.withLock { $0.removedFriends.append(friendUid) }
    }
}
