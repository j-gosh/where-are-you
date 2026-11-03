//
//  LocationStatusBanner.swift
//  where-are-you
//

import SwiftUI

/// Explains why the user's own location is missing or approximate. Renders nothing when all is well.
struct LocationStatusBanner: View {
    let status: LocationService.Status
    let isAccuracyReduced: Bool
    let requestPermission: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let message {
            HStack(spacing: 12) {
                Image(systemName: message.systemImage)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch message.action {
                case .allow:
                    Button("Allow", action: requestPermission)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case .openSettings:
                    Button("Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case nil:
                    EmptyView()
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("locationBanner")
        }
    }

    private enum Action {
        case allow
        case openSettings
    }

    private struct Message {
        let systemImage: String
        let text: LocalizedStringKey
        let action: Action?
    }

    private var message: Message? {
        switch status {
        case .needsPermission:
            Message(
                systemImage: "location",
                text: "Allow location access to see yourself on the map.",
                action: .allow
            )
        case .denied:
            Message(
                systemImage: "location.slash",
                text: "Location access is off. Turn it on in Settings to see yourself on the map.",
                action: .openSettings
            )
        case .restricted:
            Message(
                systemImage: "lock",
                text: "Location access is restricted on this device.",
                action: nil
            )
        case .unavailable:
            Message(
                systemImage: "location.magnifyingglass",
                text: "Can't find your location right now.",
                action: nil
            )
        case .available where isAccuracyReduced, .locating where isAccuracyReduced:
            Message(
                systemImage: "location.circle",
                text: "Precise Location is off, so your location is approximate.",
                action: .openSettings
            )
        case .locating, .available:
            nil
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
