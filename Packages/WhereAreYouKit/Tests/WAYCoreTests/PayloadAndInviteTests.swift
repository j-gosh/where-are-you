//
//  PayloadAndInviteTests.swift
//  WAYCoreTests
//

import Foundation
import Testing
@testable import WAYCore

struct PayloadValidationTests {
    private func profile(name: String = "Alice", emoji: String? = nil) -> Profile {
        Profile(displayName: name, avatar: Avatar(emoji: emoji, color: .red))
    }

    @Test(arguments: ["", "   ", String(repeating: "a", count: 51)])
    func rejectsBadDisplayName(name: String) {
        #expect(throws: CryptoError.invalidPayload("displayName")) {
            try profile(name: name).validate()
        }
    }

    @Test(arguments: ["🎸", "👍🏽", "❤️", "🇯🇵", "👩‍👩‍👧"])
    func acceptsSingleEmoji(emoji: String) throws {
        try profile(emoji: emoji).validate()
    }

    @Test(arguments: ["1", "#", "A", "🎸🎸", "", "ab"])
    func rejectsNonEmojiAvatar(emoji: String) {
        #expect(throws: CryptoError.invalidPayload("avatar.emoji")) {
            try profile(emoji: emoji).validate()
        }
    }

    @Test func unknownAvatarColorDecodesAsBlue() throws {
        let avatar = try JSONDecoder().decode(Avatar.self, from: Data(#"{"color":"chartreuse"}"#.utf8))
        #expect(avatar == Avatar(emoji: nil, color: .blue))
    }

    @Test(arguments: [(-90.1, 0.0), (90.1, 0.0), (0.0, 180.1), (0.0, -180.1), (Double.nan, 0.0)])
    func rejectsOutOfRangeCoordinates(latitude: Double, longitude: Double) {
        let location = SharedLocation(latitude: latitude, longitude: longitude, horizontalAccuracy: 5, isApproximate: false, timestamp: .now)
        #expect(throws: CryptoError.invalidPayload("coordinate")) {
            try location.validate()
        }
    }

    @Test(arguments: [-1.0, Double.infinity])
    func rejectsBadAccuracy(accuracy: Double) {
        let location = SharedLocation(latitude: 0, longitude: 0, horizontalAccuracy: accuracy, isApproximate: false, timestamp: .now)
        #expect(throws: CryptoError.invalidPayload("horizontalAccuracy")) {
            try location.validate()
        }
    }

    @Test(arguments: [99.0, 5_001.0])
    func rejectsAlertRadiusOutOfRange(radius: Double) {
        let request = AlertRequest(id: "a", placeName: "Home", latitude: 0, longitude: 0, radius: radius, trigger: .arrive)
        #expect(throws: CryptoError.invalidPayload("radius")) {
            try request.validate()
        }
    }

    @Test func rejectsAlertWithoutPlaceName() {
        let event = AlertEvent(alertId: "a", placeName: " ", trigger: .leave, occurredAt: .now)
        #expect(throws: CryptoError.invalidPayload("placeName")) {
            try event.validate()
        }
    }
}

struct InviteLinkTests {
    let base = URL(string: "https://github.com/ItsYaBoyJG/where-are-you")!
    let keyId = IdentityKey.generate().publicIdentity.keyId

    @Test func generatedTokensAreValidAndUnique() throws {
        let tokens = (0..<20).map { _ in InviteLink.generateToken() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            _ = try InviteLink(token: token, inviterKeyId: keyId, inviterName: nil)
        }
    }

    @Test(arguments: [nil, "Olivia", "Zoë & Ana + 1 = #friends?"])
    func urlRoundTrips(name: String?) throws {
        let invite = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: name)
        let url = try invite.url(base: base)
        #expect(try InviteLink(url: url) == invite)
    }

    @Test func inviteTravelsInFragmentNotQuery() throws {
        let invite = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: "Olivia")
        let url = try invite.url(base: base)

        #expect(url.query() == nil)
        #expect(url.fragment()?.contains(invite.token) == true)
        #expect(url.absoluteString.hasPrefix(base.absoluteString + "#"))
    }

    @Test func worksWithCustomScheme() throws {
        let invite = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: nil)
        let url = try invite.url(base: URL(string: "whereareyou://invite")!)
        #expect(try InviteLink(url: url) == invite)
    }

    @Test func blankNameBecomesNil() throws {
        let invite = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: "   ")
        #expect(invite.inviterName == nil)
    }

    @Test func rejectsTooLongName() {
        #expect(throws: InviteLinkError.invalidName) {
            try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: String(repeating: "x", count: 51))
        }
    }

    @Test(arguments: ["", "short", String(repeating: "A", count: 42), String(repeating: "+", count: 43)])
    func rejectsBadToken(token: String) {
        #expect(throws: InviteLinkError.invalidToken) {
            try InviteLink(token: token, inviterKeyId: keyId, inviterName: nil)
        }
    }

    @Test(arguments: ["", "tooShort", String(repeating: "/", count: 22)])
    func rejectsBadKeyId(keyId: String) {
        #expect(throws: InviteLinkError.invalidKeyId) {
            try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: nil)
        }
    }

    @Test(arguments: [
        "https://github.com/ItsYaBoyJG/where-are-you",
        "https://github.com/ItsYaBoyJG/where-are-you#readme",
        "https://example.com/#v=1&t=abc",
    ])
    func rejectsUrlsThatAreNotInvites(string: String) {
        #expect(throws: InviteLinkError.notAnInvite) {
            try InviteLink(url: URL(string: string)!)
        }
    }

    @Test func rejectsFutureVersion() throws {
        let token = InviteLink.generateToken()
        let url = URL(string: "https://example.com/#v=2&t=\(token)&k=\(keyId)")!
        #expect(throws: InviteLinkError.unsupportedVersion) {
            try InviteLink(url: url)
        }
    }

    @Test func codeRoundTripsAndToleratesWhitespace() throws {
        let invite = try InviteLink(token: InviteLink.generateToken(), inviterKeyId: keyId, inviterName: "Olivia")
        let parsed = try InviteLink(code: "  \(invite.code)\n")

        #expect(parsed.token == invite.token)
        #expect(parsed.inviterKeyId == invite.inviterKeyId)
        #expect(parsed.inviterName == nil)
    }

    @Test(arguments: ["", "no-dot", "a.b.c"])
    func rejectsMalformedCode(code: String) {
        #expect(throws: InviteLinkError.notAnInvite) {
            try InviteLink(code: code)
        }
    }
}
