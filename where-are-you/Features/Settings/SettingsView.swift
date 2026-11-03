//
//  SettingsView.swift
//  where-are-you
//

import SwiftUI
import WAYCore

struct SettingsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if let current = session.account {
                    Section {
                        NavigationLink {
                            ProfileEditorView(mode: .edit, initialProfile: current.profile)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(avatar: current.profile.avatar, name: current.profile.displayName, size: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(current.profile.displayName)
                                        .font(.headline)
                                    Text("Edit name and avatar")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("editProfile")
                    }

                    LocationSharingSection()
                    NotificationsSection()
                    AlertsOnYouSection()

                    Section {
                        LabeledContent("Key ID") {
                            Text(current.identity.publicIdentity.keyId)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("Encryption")
                    } footer: {
                        Text("Your profile and locations are encrypted on this device with this key. It reaches your other devices through iCloud Keychain.")
                    }
                }

                Section {
                    Button("Sign Out") {
                        Task { await session.signOut() }
                    }
                    Button("Delete Account", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } footer: {
                    if session.isUsingEmulator {
                        Text("Connected to the local Firebase emulators.")
                    }
                }
                .disabled(session.isWorking)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if session.isWorking {
                    ProgressView()
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) {
                    Task { await session.deleteAccount() }
                }
            } message: {
                Text("This permanently deletes your profile, your friends list, and everything you've shared. You'll confirm with Apple first. It can't be undone.")
            }
            .sessionErrorAlert()
        }
    }
}

/// The master switch, which device shares, and the Always permission background sharing needs.
private struct LocationSharingSection: View {
    @Environment(SharingService.self) private var sharing
    @Environment(LocationService.self) private var locationService
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Share My Location", isOn: Binding(
                get: { sharing.settings.isEnabled },
                set: { isOn in
                    perform { try await sharing.setSharingEnabled(isOn) }
                    if isOn {
                        locationService.requestAlwaysAuthorization()
                    }
                }
            ))
            .accessibilityIdentifier("shareMyLocationToggle")

            if sharing.settings.isEnabled {
                LabeledContent("My Location", value: deviceDescription)
                if !sharing.isThisDeviceActive {
                    Button("Use This Device as My Location") {
                        perform { try await sharing.useThisDevice() }
                    }
                }
                if locationService.authorization != .always {
                    Button("Share in the Background") {
                        if locationService.authorization == .whenInUse {
                            locationService.requestAlwaysAuthorization()
                        } else if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }
        } header: {
            Text("Location Sharing")
        } footer: {
            if sharing.settings.isEnabled && locationService.authorization != .always {
                Text("Friends only see updates while Where Are You is open. Allow location access \"Always\" to keep sharing in the background.")
            } else {
                Text("Choose who sees your location from each friend's page. Locations are end-to-end encrypted.")
            }
        }
        .errorAlert($errorMessage)
    }

    private var deviceDescription: String {
        switch sharing.settings.activeDeviceId {
        case nil: String(localized: "Not Set")
        case sharing.deviceId: String(localized: "This Device")
        default: String(localized: "Another Device")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Receiving alerts about friends, and the system notification permission.
private struct NotificationsSection: View {
    @Environment(AlertService.self) private var alerts
    @Environment(PushService.self) private var push
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Location Alerts", isOn: Binding(
                get: { alerts.preferences.receiveAlerts },
                set: { isOn in
                    Task {
                        do {
                            try await alerts.updatePreferences { $0.receiveAlerts = isOn }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            ))
            switch push.permission {
            case .notDetermined:
                Button("Allow Notifications") {
                    Task { await push.requestPermission() }
                }
            case .denied:
                Button("Turn On Notifications in Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            case .allowed:
                EmptyView()
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get notified when friends arrive at or leave places you choose. Notifications are decrypted on this device.")
        }
        .task { await push.refreshPermission() }
        .errorAlert($errorMessage)
    }
}

/// Alerts friends set on the user, which their device watches for.
private struct AlertsOnYouSection: View {
    @Environment(AlertService.self) private var alerts
    @Environment(FriendsStore.self) private var friendsStore
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Allow Friends to Set Alerts", isOn: Binding(
                get: { alerts.preferences.allowAlertsOnMe },
                set: { isOn in
                    Task {
                        do {
                            try await alerts.updatePreferences { $0.allowAlertsOnMe = isOn }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            ))
            if alerts.alertsOnMe.isEmpty {
                Text("No one has set an alert on you.")
                    .foregroundStyle(.secondary)
            }
            ForEach(alerts.alertsOnMe) { alert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(friendsStore.friend(id: alert.requesterUid)?.displayName ?? String(localized: "A friend"))
                        .font(.headline)
                    Text(alert.request.map(\.summary) ?? String(localized: "Couldn't read this alert."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        Task {
                            do {
                                try await alerts.removeAlertOnMe(alert.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Alerts on You")
        } footer: {
            if alerts.overLimitCount > 0 {
                Text("iOS can watch \(AlertPlanner.monitoringLimit) places at a time, so \(alerts.overLimitCount) of these aren't active. Remove some to activate the rest.")
            } else {
                Text("Your device tells these friends when you arrive or leave. Swipe to remove one.")
            }
        }
        .errorAlert($errorMessage)
    }
}

extension AlertRequest {
    /// "Arriving at Home": what the alert watches for.
    var summary: String {
        switch trigger {
        case .arrive: String(localized: "Arriving at \(placeName)")
        case .leave: String(localized: "Leaving \(placeName)")
        }
    }
}

extension View {
    /// A plain "Something Went Wrong" alert for an optional message.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Something Went Wrong",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
