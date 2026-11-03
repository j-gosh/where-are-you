//
//  SecurityCodeView.swift
//  where-are-you
//

import SwiftUI
import WAYCore

/// The 60-digit code two friends compare to confirm nobody swapped their keys.
struct SecurityCodeView: View {
    let friendID: Friend.ID

    @Environment(FriendsStore.self) private var friendsStore
    @Environment(SessionModel.self) private var session
    @State private var errorMessage: String?

    var body: some View {
        if let friend = friendsStore.friend(id: friendID),
           let theirs = friend.identity,
           let mine = session.account?.identity.publicIdentity {
            List {
                Section {
                    codeGrid(SecurityCode.digits(mine, theirs))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } footer: {
                    Text("Compare these numbers with \(friend.displayName) in person or on a call. If they match on both phones, nobody else can read what you share with each other.")
                }

                Section {
                    LabeledContent("Status", value: friend.keyStatus.label)
                    if friend.keyStatus != .trusted(.compared) {
                        Button("Mark as Verified") {
                            do {
                                try friendsStore.markKeyVerified(friend.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                } footer: {
                    Text("Only mark the code as verified after checking every group with \(friend.displayName).")
                }
            }
            .navigationTitle("Security Code")
            .alert(
                "Couldn't Save",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        } else {
            ContentUnavailableView(
                "Security Code Unavailable",
                systemImage: "lock.slash",
                description: Text("Their encryption key hasn't loaded yet.")
            )
        }
    }

    private func codeGrid(_ code: String) -> some View {
        let groups = code.split(separator: " ").map(String.init)
        return Grid(horizontalSpacing: 20, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: groups.count, by: 3)), id: \.self) { row in
                GridRow {
                    // By index: two groups can hold the same digits.
                    ForEach(row..<min(row + 3, groups.count), id: \.self) { index in
                        Text(groups[index])
                            .font(.title3.monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(code)
        .accessibilityIdentifier("securityCodeDigits")
    }
}
