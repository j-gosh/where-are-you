//
//  InviteMessage.swift
//  Shared by the app and the Messages extension.
//

import Messages
import UIKit
import WAYCore

/// The Messages bubble an invite travels in.
@MainActor
enum InviteMessage {
    /// Opens the app, optionally with an invite in the fragment. Registered in Config/App-Info.plist.
    static let appURL = URL(string: "whereareyou://invite")!

    /// Where the bubble's link goes when opened outside Messages, e.g. on a Mac. The invite
    /// travels in the URL fragment, which browsers never send to the server.
    static func landingURL(in bundle: Bundle = .main) -> URL {
        (bundle.object(forInfoDictionaryKey: "WAYInviteLandingURL") as? String)
            .flatMap { URL(string: $0) } ?? fallbackLandingURL
    }

    private static let fallbackLandingURL = URL(string: "https://github.com/ItsYaBoyJG/where-are-you")!

    static func make(for link: InviteLink, landingURL: URL) throws -> MSMessage {
        let layout = MSMessageTemplateLayout()
        layout.image = bubbleImage()
        layout.caption = String(localized: "Let's share locations")
        layout.subcaption = link.inviterName.map { String(localized: "From \($0) on Where Are You") }
            ?? String(localized: "On Where Are You")

        let message = MSMessage(session: MSSession())
        message.layout = layout
        message.url = try link.url(base: landingURL)
        message.summaryText = String(localized: "Invite to share locations")
        return message
    }

    private static func bubbleImage() -> UIImage {
        let size = CGSize(width: 600, height: 300)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.systemBlue.cgColor, UIColor.systemTeal.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
            if let symbol = UIImage(systemName: "location.circle.fill", withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }
}
