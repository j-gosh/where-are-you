//
//  FriendPin.swift
//  where-are-you
//

import SwiftUI
import WAYCore

/// A friend's avatar on the map. Dimmed when their location is stale.
struct FriendPin: View {
    let friend: Friend
    let location: SharedLocation
    let isSelected: Bool
    let now: Date

    var body: some View {
        AvatarView(avatar: friend.avatar, name: friend.displayName, size: isSelected ? 52 : 40)
            .padding(3)
            .background(.background, in: Circle())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .opacity(location.isStale(at: now) ? 0.55 : 1)
            .animation(.snappy, value: isSelected)
            .accessibilityElement()
            .accessibilityLabel(friend.displayName)
            .accessibilityValue(LocationFormatting.lastUpdated(location.timestamp, now: now))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
