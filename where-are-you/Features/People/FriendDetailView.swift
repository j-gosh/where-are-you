//
//  FriendDetailView.swift
//  where-are-you
//

import MapKit
import OSLog
import SwiftUI
import WAYCore

struct FriendDetailView: View {
    let friendID: Friend.ID

    @Environment(FriendsStore.self) private var friendsStore
    @Environment(LocationService.self) private var locationService
    @Environment(\.addressLookup) private var addressLookup
    @Environment(\.dismiss) private var dismiss

    @State private var address: AddressState = .loading
    @State private var isCreatingAlert = false
    @State private var isConfirmingRemoval = false
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        if let friend = friendsStore.friend(id: friendID) {
            TimelineView(.everyMinute) { context in
                details(for: friend, now: context.date)
            }
            .navigationTitle(friend.displayName)
            .task(id: friend.location.map(AddressKey.init)) {
                await loadAddress(for: friend.location)
            }
            .sheet(isPresented: $isCreatingAlert) {
                CreateAlertView(
                    friend: friend,
                    start: friend.location?.coordinate
                        ?? locationService.userLocation?.coordinate
                        ?? CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
                )
            }
            .confirmationDialog("Remove \(friend.displayName)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                Button("Remove Friend", role: .destructive) {
                    Task { await remove(friend) }
                }
            } message: {
                Text("You'll stop seeing each other, and any alerts either of you set are deleted. You can invite them again later.")
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        } else {
            ContentUnavailableView(
                "Not a Friend",
                systemImage: "person.slash",
                description: Text("You and this person are no longer friends.")
            )
        }
    }

    private func details(for friend: Friend, now: Date) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(avatar: friend.avatar, name: friend.displayName, size: 72)
                    Text(friend.displayName)
                        .font(.title2.bold())
                    if let location = friend.location {
                        Text("Updated \(LocationFormatting.lastUpdated(location.timestamp, now: now))")
                            .foregroundStyle(.secondary)
                        if location.isApproximate {
                            Label("Approximate location", systemImage: "location.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if friend.keyStatus == .changed {
                keyChangedSection(for: friend)
            }

            if let problem = friend.problem {
                Section {
                    Label(problem.explanation, systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            }

            if let location = friend.location {
                Section {
                    LabeledContent("Address") {
                        switch address {
                        case .loading: ProgressView()
                        case .found(let text): Text(text)
                        case .unavailable: Text("Unavailable")
                        }
                    }
                    if let distance = LocationFormatting.distance(from: locationService.userLocation, to: location) {
                        LabeledContent("Distance", value: distance)
                    }
                }
                Section {
                    Button {
                        openDirections(to: location, name: friend.displayName)
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                }
            } else if friend.problem == nil {
                Section {
                    Label(
                        friend.isSharingLocation ? "Location not available" : "\(friend.displayName) isn't sharing their location with you.",
                        systemImage: "location.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            SharingSection(friend: friend)
            FriendAlertsSection(friend: friend, isCreatingAlert: $isCreatingAlert)

            if friend.identity != nil {
                Section {
                    NavigationLink {
                        SecurityCodeView(friendID: friend.id)
                    } label: {
                        LabeledContent("Security Code", value: friend.keyStatus.label)
                    }
                    .accessibilityIdentifier("securityCode")
                } footer: {
                    Text("Compare codes with \(friend.displayName) to make sure your connection is private.")
                }
            }

            Section {
                Button("Remove Friend", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(isRemoving)
            }
        }
    }

    private func keyChangedSection(for friend: Friend) -> some View {
        Section {
            Label {
                Text("\(friend.displayName)'s security code changed. That's normal after they reinstall or reset their key, but compare codes if you weren't expecting it.")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
            NavigationLink("Compare Codes") {
                SecurityCodeView(friendID: friend.id)
            }
            Button("Dismiss") {
                do {
                    try friendsStore.acceptKeyChange(friend.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .accessibilityIdentifier("keyChangedNotice")
    }

    private func remove(_ friend: Friend) async {
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await friendsStore.removeFriend(friend.id)
            dismiss()
        } catch {
            Logger.friends.error("Removing a friend failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = String(localized: "Couldn't remove \(friend.displayName). \(error.localizedDescription)")
        }
    }

    private func loadAddress(for location: SharedLocation?) async {
        guard let location else { return }
        address = .loading
        do {
            let result = try await addressLookup.address(latitude: location.latitude, longitude: location.longitude)
            guard !Task.isCancelled else { return }
            address = result.map(AddressState.found) ?? .unavailable
        } catch {
            guard !Task.isCancelled else { return }
            Logger.maps.error("Reverse geocoding failed: \(error.localizedDescription, privacy: .public)")
            address = .unavailable
        }
    }

    private func openDirections(to location: SharedLocation, name: String) {
        let mapItem: MKMapItem
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            mapItem = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil)
        } else {
            mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        }
        #else
        mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        #endif
        mapItem.name = name
        if !mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault]) {
            Logger.maps.error("Opening Maps for directions failed")
        }
    }
}

/// Whether the user shares their own location with this friend.
private struct SharingSection: View {
    let friend: Friend

    @Environment(SharingService.self) private var sharing
    @Environment(LocationService.self) private var locationService
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Share My Location", isOn: Binding(
                get: { sharing.settings.isSharing(with: friend.id) },
                set: { isOn in
                    Task {
                        do {
                            try await sharing.setSharing(isOn, with: friend.id)
                            if isOn {
                                locationService.requestAlwaysAuthorization()
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            ))
            .accessibilityIdentifier("shareWithFriendToggle")
        } footer: {
            Text("\(friend.displayName) sees your location only while this is on.")
        }
        .errorAlert($errorMessage)
    }
}

/// Alerts the user set on this friend, and alert preferences for them.
private struct FriendAlertsSection: View {
    let friend: Friend
    @Binding var isCreatingAlert: Bool

    @Environment(AlertService.self) private var alerts
    @State private var setAlerts: [SetAlert] = []
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(setAlerts) { alert in
                Label(alert.request.summary, systemImage: alert.request.trigger == .arrive ? "arrow.down.right.circle" : "arrow.up.right.circle")
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            run { try await alerts.deleteAlert(alert.id, on: friend.id) }
                        }
                    }
            }
            Button {
                isCreatingAlert = true
            } label: {
                Label("Add Location Alert", systemImage: "bell.badge")
            }
            .disabled(friend.identity == nil)
            .accessibilityIdentifier("addLocationAlert")

            Toggle("Alerts from \(friend.displayName)", isOn: Binding(
                get: { !alerts.preferences.mutedAlertSenders.contains(friend.id) },
                set: { isOn in
                    run {
                        try await alerts.updatePreferences { preferences in
                            if isOn {
                                preferences.mutedAlertSenders.remove(friend.id)
                            } else {
                                preferences.mutedAlertSenders.insert(friend.id)
                            }
                        }
                    }
                }
            ))
            Toggle("Let \(friend.displayName) Set Alerts on You", isOn: Binding(
                get: { !alerts.preferences.blockedAlertRequesters.contains(friend.id) },
                set: { isOn in
                    run {
                        try await alerts.updatePreferences { preferences in
                            if isOn {
                                preferences.blockedAlertRequesters.remove(friend.id)
                            } else {
                                preferences.blockedAlertRequesters.insert(friend.id)
                            }
                        }
                    }
                }
            ))
        } header: {
            Text("Notify Me")
        } footer: {
            Text("Get a notification when \(friend.displayName) arrives at or leaves a place. Swipe an alert to delete it.")
        }
        .task(id: friend.id) {
            do {
                for try await alerts in alerts.alertsSet(on: friend.id) {
                    setAlerts = alerts
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .errorAlert($errorMessage)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension FriendRecord.KeyStatus {
    var label: String {
        switch self {
        case .unknown: String(localized: "Loading")
        case .trusted(.firstUse): String(localized: "Not Verified")
        case .trusted(.invite): String(localized: "Checked by Invite")
        case .trusted(.compared): String(localized: "Verified")
        case .changed: String(localized: "Changed")
        }
    }
}

extension FriendRecord.Problem {
    var explanation: String {
        switch self {
        case .waitingForProfile: String(localized: "Waiting for them to finish connecting.")
        case .keyUnavailable: String(localized: "Loading their encryption key.")
        case .waitingForNewKey: String(localized: "Waiting for an update encrypted with your current keys.")
        case .unreadable: String(localized: "Their latest update couldn't be read.")
        }
    }
}

private enum AddressState: Equatable {
    case loading
    case found(String)
    case unavailable
}

/// Rounds to about 100 m so small movements don't trigger another (rate-limited) lookup.
private struct AddressKey: Hashable {
    let latitude: Int
    let longitude: Int

    init(_ location: SharedLocation) {
        latitude = Int((location.latitude * 1_000).rounded())
        longitude = Int((location.longitude * 1_000).rounded())
    }
}

#if DEBUG
#Preview {
    let dependencies = AppDependencies.preview
    NavigationStack {
        FriendDetailView(friendID: "LSDLVJH234785")
    }
    .dependencies(dependencies)
    .previewFriends()
}
#endif
