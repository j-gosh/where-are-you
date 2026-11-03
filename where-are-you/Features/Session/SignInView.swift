//
//  SignInView.swift
//  where-are-you
//

import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    /// The nonce for the request in flight; its hash went to Apple.
    @State private var nonce = ""
    #if DEBUG
    @State private var isAskingForTestName = false
    @State private var testName = ""
    #endif

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Where Are You")
                    .font(.largeTitle.bold())
                Text("See where your friends are, privately.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 20) {
                Feature(
                    systemImage: "lock.fill",
                    title: "End-to-end encrypted",
                    detail: "Only the friends you choose can see where you are. Not even the server can."
                )
                Feature(
                    systemImage: "person.2.fill",
                    title: "You're in control",
                    detail: "Share with each friend separately, and stop whenever you like."
                )
                Feature(
                    systemImage: "bell.badge.fill",
                    title: "Arrive and leave alerts",
                    detail: "Know when a friend gets home safe."
                )
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    nonce = AppleSignIn.makeNonce()
                    AppleSignIn.configure(request, nonce: nonce)
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .accessibilityIdentifier("signInWithApple")

                #if DEBUG
                if session.isUsingEmulator {
                    Button("Sign In with Emulator Test Account") {
                        isAskingForTestName = true
                    }
                    .font(.footnote)
                }
                #endif
            }
            .disabled(session.isWorking)
        }
        .padding(24)
        .frame(maxWidth: 500)
        .overlay {
            if session.isWorking {
                ProgressView()
            }
        }
        #if DEBUG
        .alert("Test Account", isPresented: $isAskingForTestName) {
            TextField("Name", text: $testName)
            Button("Sign In") {
                Task { await session.signInWithEmulatorTestAccount(named: testName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each name is a separate account in the Auth emulator.")
        }
        #endif
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            do {
                let credential = try AppleSignIn.credential(from: authorization, nonce: nonce)
                Task { await session.signIn(with: credential) }
            } catch {
                session.reportSignInFailure(error)
            }
        case .failure(let error):
            if !AppleSignIn.isCancellation(error) {
                session.reportSignInFailure(error)
            }
        }
    }
}

private struct Feature: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
