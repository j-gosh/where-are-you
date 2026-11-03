//
//  InviteLink.swift
//  WAYCore
//

import CryptoKit
import Foundation

public enum InviteLinkError: Error, Equatable {
    case notAnInvite
    case unsupportedVersion
    case invalidToken
    case invalidKeyId
    case invalidName
    case invalidBaseURL
}

/// An invitation to become friends, sent through Messages.
///
/// The token names the `invites/{token}` document. The inviter's key ID travels over iMessage,
/// which Apple encrypts end to end, so the invitee can check that the public key Firestore
/// returns for the inviter is the one the inviter actually has.
public struct InviteLink: Hashable, Sendable, Identifiable {
    public static let currentVersion = 1
    /// 32 random bytes, base64url-encoded.
    public static let tokenLength = 43

    public let token: String
    public let inviterKeyId: String

    public var id: String { token }
    /// Display only. The inviter's verified profile arrives encrypted after accepting.
    public let inviterName: String?

    public init(token: String, inviterKeyId: String, inviterName: String?) throws {
        guard token.count == Self.tokenLength, Data(base64URLEncoded: token)?.count == 32 else {
            throw InviteLinkError.invalidToken
        }
        guard inviterKeyId.count == PublicIdentity.keyIdLength, Data(base64URLEncoded: inviterKeyId)?.count == 16 else {
            throw InviteLinkError.invalidKeyId
        }
        let name = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.count > Profile.maxNameLength {
            throw InviteLinkError.invalidName
        }
        self.token = token
        self.inviterKeyId = inviterKeyId
        self.inviterName = name?.isEmpty == false ? name : nil
    }

    public static func generateToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    // MARK: URL form

    /// `base` with the invite in the fragment. Browsers never send fragments to servers, so if
    /// the link is opened somewhere without the app, the token doesn't reach `base`'s host.
    public func url(base: URL) throws -> URL {
        var fields = URLComponents()
        fields.queryItems = [
            URLQueryItem(name: "v", value: String(Self.currentVersion)),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "k", value: inviterKeyId),
        ]
        if let inviterName {
            fields.queryItems?.append(URLQueryItem(name: "n", value: inviterName))
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw InviteLinkError.invalidBaseURL
        }
        components.percentEncodedFragment = fields.percentEncodedQuery
        guard let url = components.url else {
            throw InviteLinkError.invalidBaseURL
        }
        return url
    }

    public init(url: URL) throws {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment else {
            throw InviteLinkError.notAnInvite
        }
        var fields = URLComponents()
        fields.percentEncodedQuery = fragment
        let items = fields.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let version = value("v"), let token = value("t"), let keyId = value("k") else {
            throw InviteLinkError.notAnInvite
        }
        guard version == String(Self.currentVersion) else {
            throw InviteLinkError.unsupportedVersion
        }
        try self.init(token: token, inviterKeyId: keyId, inviterName: value("n"))
    }

    // MARK: Code form

    /// Compact form to copy and paste when Messages isn't available: `<token>.<keyId>`.
    public var code: String {
        "\(token).\(inviterKeyId)"
    }

    public init(code: String) throws {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw InviteLinkError.notAnInvite
        }
        try self.init(token: String(parts[0]), inviterKeyId: String(parts[1]), inviterName: nil)
    }
}
