//
//  RootView.swift
//  where-are-you
//

import OSLog
import SwiftUI
import WAYCore

/// Picks the screen for the current session phase.
struct RootView: View {
    let dependencies: AppDependencies

    var body: some View {
        if let session = dependencies.session {
            SessionRootView(makeFriendsRepository: dependencies.makeFriendsRepository)
                .environment(session)
        } else {
            ContentUnavailableView(
                "Not Configured",
                systemImage: "gearshape.2",
                description: Text("This build has no Firebase configuration. Add GoogleService-Info.plist to the where-are-you folder and rebuild. The README explains how.")
            )
        }
    }
}

private struct SessionRootView: View {
    let makeFriendsRepository: @MainActor (Account) -> any FriendsRepository

    @Environment(SessionModel.self) private var session
    @Environment(LocationService.self) private var locationService
    @AppStorage("hasSeenLocationPrimer") private var hasSeenLocationPrimer = false
    /// An invite opened from a link, kept until the account is ready to accept it.
    @State private var pendingInvite: InviteLink?

    var body: some View {
        content
            .animation(.default, value: session.phase)
            .task {
                await session.run()
            }
            .onOpenURL { url in
                do {
                    pendingInvite = try InviteLink(url: url)
                } catch {
                    // Plain whereareyou:// links just open the app.
                    Logger.friends.notice("Opened a link without a usable invite: \(String(describing: error), privacy: .public)")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView()
        case .settingUp:
            ProgressView("Setting up encryption…")
        case .signedOut:
            SignInView()
                .sessionErrorAlert()
        case .keyMissing:
            KeyMissingView()
                .sessionErrorAlert()
        case .needsProfile:
            NavigationStack {
                ProfileEditorView(mode: .create, initialProfile: nil, suggestedName: session.suggestedName)
            }
            .sessionErrorAlert()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Connect", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { session.retry() }
                    .buttonStyle(.borderedProminent)
                Button("Sign Out") { Task { await session.signOut() } }
            }
            .sessionErrorAlert()
        case .ready:
            if !hasSeenLocationPrimer && locationService.authorization == .notDetermined {
                LocationPrimerView { hasSeenLocationPrimer = true }
            } else if let account = session.account {
                SignedInView(account: account, makeFriendsRepository: makeFriendsRepository, pendingInvite: $pendingInvite)
                    // A different account gets a fresh friends store.
                    .id(account.uid)
            }
        }
    }
}

/// Everything that needs a set-up account: the map, friends, and pending invites.
private struct SignedInView: View {
    @Binding var pendingInvite: InviteLink?

    @Environment(SessionModel.self) private var session
    @State private var friendsStore: FriendsStore

    init(account: Account, makeFriendsRepository: @MainActor (Account) -> any FriendsRepository, pendingInvite: Binding<InviteLink?>) {
        _pendingInvite = pendingInvite
        _friendsStore = State(initialValue: FriendsStore(repository: makeFriendsRepository(account)))
    }

    var body: some View {
        MapScreen()
            .environment(friendsStore)
            .onChange(of: session.account?.profile) { _, profile in
                guard let profile else { return }
                Task { await friendsStore.shareProfile(profile) }
            }
            .sheet(item: $pendingInvite) { link in
                AcceptInviteView(link: link)
                    .environment(friendsStore)
            }
    }
}

extension View {
    /// Shows `SessionModel.actionError` as an alert. Attach it to one visible view at a time.
    func sessionErrorAlert() -> some View {
        modifier(SessionErrorAlert())
    }
}

private struct SessionErrorAlert: ViewModifier {
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        content.alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { session.actionError != nil },
                set: { if !$0 { session.actionError = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(session.actionError ?? "")
        }
    }
}
