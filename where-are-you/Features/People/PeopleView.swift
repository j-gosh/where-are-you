//
//  PeopleView.swift
//  where-are-you
//

import SwiftUI

/// The friend list and friend details. Shown in a bottom sheet on iPhone and a side panel on iPad.
struct PeopleView: View {
    /// Shared with the map, so picking a pin opens that friend here and vice versa.
    @Binding var selection: Friend.ID?

    @Environment(FriendsStore.self) private var friendsStore
    @Environment(SessionModel.self) private var session
    @State private var isShowingSettings = false
    @State private var isAddingFriend = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("People")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $selection) { id in
                    FriendDetailView(friendID: id)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isAddingFriend = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("Add Friend")
                        .accessibilityIdentifier("addFriendButton")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        settingsButton
                    }
                }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isAddingFriend) {
            AddFriendView()
        }
    }

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            if let profile = session.account?.profile {
                AvatarView(avatar: profile.avatar, name: profile.displayName, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settingsButton")
    }

    @ViewBuilder
    private var content: some View {
        switch friendsStore.loadState {
        case .loading where friendsStore.friends.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where friendsStore.friends.isEmpty:
            ContentUnavailableView {
                Label("Couldn't Load Friends", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { friendsStore.retry() }
            }
        default:
            if friendsStore.friends.isEmpty {
                ContentUnavailableView {
                    Label("No Friends Yet", systemImage: "person.2")
                } description: {
                    Text("Invite friends to see each other here.")
                } actions: {
                    Button("Add Friend") { isAddingFriend = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                friendList
            }
        }
    }

    private var friendList: some View {
        TimelineView(.everyMinute) { context in
            List(friendsStore.friends) { friend in
                Button {
                    selection = friend.id
                } label: {
                    FriendRow(friend: friend, now: context.date)
                }
                .accessibilityIdentifier("friendRow.\(friend.id)")
            }
            .listStyle(.plain)
        }
    }
}

struct FriendRow: View {
    let friend: Friend
    let now: Date

    @Environment(LocationService.self) private var locationService

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(avatar: friend.avatar, name: friend.displayName, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if friend.keyStatus == .changed {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Security code changed")
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let problem = friend.problem {
            return problem.explanation
        }
        guard friend.isSharingLocation else {
            return String(localized: "Not sharing their location")
        }
        guard let location = friend.location else {
            return String(localized: "Location not available")
        }
        let updated = LocationFormatting.lastUpdated(location.timestamp, now: now)
        guard let distance = LocationFormatting.distance(from: locationService.userLocation, to: location) else {
            return updated
        }
        return "\(updated) · \(distance)"
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selection: Friend.ID?
    let dependencies = AppDependencies.preview
    PeopleView(selection: $selection)
        .dependencies(dependencies)
        .previewFriends()
        .task { await dependencies.session?.run() }
}
#endif
