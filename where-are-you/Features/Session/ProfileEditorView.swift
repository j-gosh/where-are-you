//
//  ProfileEditorView.swift
//  where-are-you
//

import SwiftUI
import WAYCore

/// Name and avatar. Used to create the profile after sign-in and to edit it from Settings.
struct ProfileEditorView: View {
    enum Mode {
        case create
        case edit
    }

    /// Emoji offered as avatars. Each must pass `Profile.validate()`.
    static let emojiChoices = [
        "😀", "😎", "🤠", "🥳", "🐶", "🐱", "🦊", "🐼", "🐸", "🦄", "🌸", "🌵",
        "🍕", "☕️", "⚽️", "🏀", "🎸", "🎮", "🚲", "✈️", "🏔️", "🌊", "🔥", "⭐️",
    ]

    let mode: Mode

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emoji: String?
    @State private var color: AvatarColor

    init(mode: Mode, initialProfile: Profile?, suggestedName: String? = nil) {
        self.mode = mode
        _name = State(initialValue: initialProfile?.displayName ?? suggestedName ?? "")
        _emoji = State(initialValue: initialProfile?.avatar.emoji)
        _color = State(initialValue: initialProfile?.avatar.color ?? AvatarColor.allCases.randomElement() ?? .blue)
    }

    private var profile: Profile {
        Profile(
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: Avatar(emoji: emoji, color: color)
        )
    }

    private var isValid: Bool {
        (try? profile.validate()) != nil
    }

    var body: some View {
        Form {
            Section {
                AvatarView(avatar: profile.avatar, name: profile.displayName, size: 96)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .accessibilityIdentifier("profileNameField")
                    .onChange(of: name) { _, newValue in
                        if newValue.count > Profile.maxNameLength {
                            name = String(newValue.prefix(Profile.maxNameLength))
                        }
                    }
            } header: {
                Text("Name")
            } footer: {
                Text("Only friends you share with see your name and avatar. They're end-to-end encrypted.")
            }

            Section("Color") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 12) {
                    ForEach(AvatarColor.allCases, id: \.self) { choice in
                        Button {
                            color = choice
                        } label: {
                            Circle()
                                .fill(choice.color.gradient)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if choice == color {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.rawValue.capitalized)
                        .accessibilityAddTraits(choice == color ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Avatar") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    choiceButton(label: Text(AvatarView.initials(for: profile.displayName)).font(.headline), isSelected: emoji == nil) {
                        emoji = nil
                    }
                    .accessibilityLabel("Initials")
                    ForEach(Self.emojiChoices, id: \.self) { choice in
                        choiceButton(label: Text(choice).font(.title2), isSelected: emoji == choice) {
                            emoji = choice
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(mode == .create ? "Create Your Profile" : "Edit Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .create ? "Continue" : "Save") {
                    Task {
                        if await session.saveProfile(profile), mode == .edit {
                            dismiss()
                        }
                    }
                }
                .disabled(!isValid || session.isWorking)
            }
            if mode == .create {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out") { Task { await session.signOut() } }
                }
            }
        }
        .disabled(session.isWorking)
    }

    private func choiceButton(label: some View, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .frame(width: 44, height: 44)
                .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
