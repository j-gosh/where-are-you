//
//  AddFriendView.swift
//  where-are-you
//

import Messages
import SwiftUI
import UIKit
import WAYCore

/// Invite friends with a Messages bubble or an invite code, or accept a code.
struct AddFriendView: View {
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(\.dismiss) private var dismiss
    @State private var inviteCode: InviteLink?
    @State private var compose: ComposeRequest?
    @State private var isCreating = false
    @State private var codeToAccept = ""
    @State private var pendingAccept: InviteLink?
    @State private var errorMessage: String?

    private struct ComposeRequest: Identifiable {
        let id = UUID()
        let message: MSMessage
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await inviteWithMessages() }
                    } label: {
                        Label("Invite with Messages", systemImage: "message.fill")
                    }
                    .disabled(!MessageComposeView.canSend || isCreating)
                } footer: {
                    if MessageComposeView.canSend {
                        Text("Sends an invite bubble. The first person to tap it can accept.")
                    } else {
                        Text("Messages isn't available on this device. Use an invite code instead.")
                    }
                }

                Section {
                    if let inviteCode {
                        Text(inviteCode.code)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("inviteCode")
                        ShareLink(item: String(localized: "Add me on Where Are You with this invite code: \(inviteCode.code)")) {
                            Label("Share Code", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = inviteCode.code
                        } label: {
                            Label("Copy Code", systemImage: "doc.on.doc")
                        }
                    } else {
                        Button("Create Invite Code") {
                            Task { await createCode() }
                        }
                        .disabled(isCreating)
                    }
                } header: {
                    Text("Invite Code")
                } footer: {
                    Text("Each code works once and expires after 3 days. Send it privately: anyone with it can become your friend.")
                }

                Section("Have a Code?") {
                    TextField("Paste an invite code", text: $codeToAccept)
                        .font(.footnote.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("inviteCodeField")
                    Button("Continue") {
                        do {
                            pendingAccept = try InviteLink(code: codeToAccept)
                        } catch {
                            errorMessage = String(localized: "That doesn't look like an invite code. Check that you copied all of it.")
                        }
                    }
                    .disabled(codeToAccept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isCreating {
                    ProgressView()
                }
            }
            .sheet(item: $pendingAccept) { link in
                AcceptInviteView(link: link)
            }
            .sheet(item: $compose) { request in
                MessageComposeView(message: request.message) { _ in
                    compose = nil
                }
                .ignoresSafeArea()
            }
            .alert(
                "Couldn't Continue",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func inviteWithMessages() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let link = try await friendsStore.createInvite()
            compose = ComposeRequest(message: try InviteMessage.make(for: link, landingURL: InviteMessage.landingURL()))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createCode() async {
        isCreating = true
        defer { isCreating = false }
        do {
            inviteCode = try await friendsStore.createInvite()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
