//
//  LocationPrimerView.swift
//  where-are-you
//

import SwiftUI

/// Explains location access before iOS asks, so the prompt arrives with context.
struct LocationPrimerView: View {
    let onFinish: () -> Void

    @Environment(LocationService.self) private var locationService

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "location.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Show Your Location")
                .font(.title.bold())
            Text("Where Are You uses your location to show you on the map. Friends only see it if you choose to share with them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                locationService.requestPermission()
                onFinish()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Not Now", action: onFinish)
        }
        .padding(24)
        .frame(maxWidth: 500)
    }
}
