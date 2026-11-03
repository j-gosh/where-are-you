//
//  MessagesRootView.swift
//  WhereAreYouMessages
//

import SwiftUI
import WAYCore

struct MessagesRootView: View {
    let model: MessagesModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut:
                openAppPrompt(String(localized: "Sign in to Where Are You first."))
            case .needsSetup:
                openAppPrompt(String(localized: "Finish setting up Where Are You first."))
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await model.load() }
                }
            case .ready:
                if let invite = model.selectedInvite {
                    receivedInvite(invite)
                } else {
                    sendPanel
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Couldn't Send the Invite",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sendPanel: some View {
        VStack(spacing: 14) {
            Label("Where Are You", systemImage: "location.circle.fill")
                .font(.headline)
            Text("Invite someone in this conversation to share locations.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.sendInvite() }
            } label: {
                if model.isSending {
                    ProgressView()
                } else {
                    Text("Send Invite")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSending)
            Text("End-to-end encrypted. The first person to tap it can accept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func receivedInvite(_ invite: InviteLink) -> some View {
        if model.isOwnInvite {
            Text("You sent this invite. It's waiting for someone to accept it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        } else {
            Text(invite.inviterName.map { String(localized: "\($0) wants to share locations") } ?? String(localized: "Invite to share locations"))
                .font(.headline)
                .multilineTextAlignment(.center)
            switch model.acceptStatus {
            case .idle, .failed:
                if case .failed(let message) = model.acceptStatus {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button("Accept") {
                    Task { await model.acceptSelectedInvite() }
                }
                .buttonStyle(.borderedProminent)
            case .accepting:
                ProgressView()
            case .accepted:
                Label("You're friends now", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Open Where Are You") { model.openApp() }
            }
        }
    }

    private func openAppPrompt(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Where Are You") { model.openApp() }
                .buttonStyle(.borderedProminent)
        }
    }
}
