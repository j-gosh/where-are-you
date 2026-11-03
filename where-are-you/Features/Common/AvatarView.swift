//
//  AvatarView.swift
//  where-are-you
//

import SwiftUI
import WAYCore

struct AvatarView: View {
    let avatar: Avatar
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(avatar.color.color.gradient)
            .overlay {
                Text(avatar.emoji ?? Self.initials(for: name))
                    .font(.system(size: size * (avatar.emoji == nil ? 0.4 : 0.55), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    nonisolated static func initials(for name: String) -> String {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .abbreviated
        if let components = formatter.personNameComponents(from: name) {
            let initials = formatter.string(from: components)
            if !initials.isEmpty {
                return initials
            }
        }
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

extension AvatarColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

#Preview {
    HStack {
        AvatarView(avatar: Avatar(emoji: nil, color: .orange), name: "Olivia Bennett")
        AvatarView(avatar: Avatar(emoji: "🎸", color: .green), name: "Liam Rodriguez", size: 64)
    }
}
