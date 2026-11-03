//
//  KeyMissingView.swift
//  where-are-you
//

import SwiftUI

/// The account's published key isn't on this device: usually iCloud Keychain hasn't synced it yet.
struct KeyMissingView: View {
    @Environment(SessionModel.self) private var session
    @State private var isConfirmingReset = false

    var body: some View {
        ContentUnavailableView {
            Label("Waiting for Your Encryption Key", systemImage: "key.horizontal")
        } description: {
            Text("You've used Where Are You on another device. Its encryption key reaches this device through iCloud Keychain, and it hasn't arrived yet. Check that iCloud Keychain is on in Settings, then try again.")
        } actions: {
            Button("Try Again") { session.retry() }
                .buttonStyle(.borderedProminent)
            Button("Create New Key", role: .destructive) { isConfirmingReset = true }
            Button("Sign Out") { Task { await session.signOut() } }
        }
        .disabled(session.isWorking)
        .confirmationDialog("Create a new encryption key?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Create New Key", role: .destructive) {
                Task { await session.resetKey() }
            }
        } message: {
            Text("Your other devices will switch to the new key. You'll set up your profile again, and friends' locations appear once they next update.")
        }
    }
}
