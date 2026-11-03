//
//  AcceptInviteView.swift
//  where-are-you
//

import SwiftUI
import WAYCore

/// Confirms an invite opened from a link or pasted as a code, then accepts it.
struct AcceptInviteView: View {
    let link: InviteLink

    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .ready

    private enum Status: Equatable {
        case ready
        case accepting
        case accepted
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: status == .accepted ? "checkmark.circle.fill" : "person.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(status == .accepted ? .green : .accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                switch status {
                case .ready, .failed:
                    Button {
                        Task { await accept() }
                    } label: {
                        Text("Accept").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                case .accepting:
                    ProgressView()
                case .accepted:
                    Button {
                        dismiss()
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .toolbar {
                if status != .accepted {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(status == .accepting)
    }

    private var title: String {
        switch status {
        case .accepted:
            String(localized: "You're Friends")
        default:
            link.inviterName.map { String(localized: "Become friends with \($0)?") } ?? String(localized: "Accept This Invite?")
        }
    }

    private var detail: String {
        switch status {
        case .ready, .accepting:
            String(localized: "You'll see each other's names. Sharing your location is up to you, friend by friend.")
        case .accepted:
            String(localized: "They'll appear in People. Their encryption key was checked against the invite.")
        case .failed(let message):
            message
        }
    }

    private func accept() async {
        status = .accepting
        do {
            try await friendsStore.acceptInvite(link)
            status = .accepted
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
