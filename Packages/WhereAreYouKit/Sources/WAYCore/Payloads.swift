//
//  Payloads.swift
//  WAYCore
//
//  Everything below is encrypted before it leaves the device. Decrypted payloads come from
//  other people's devices, so `validate()` runs on both seal and open.
//

import Foundation

public enum PayloadKind: String, Sendable, CaseIterable {
    case profile
    case location
    case alertRequest
    case alertEvent
}

public protocol SealablePayload: Codable, Sendable {
    static var kind: PayloadKind { get }
    /// Throws `CryptoError.invalidPayload` when a field is out of range.
    func validate() throws
}

// MARK: - Profile

public struct Profile: SealablePayload, Hashable {
    public static let kind = PayloadKind.profile
    public static let maxNameLength = 50

    public var displayName: String
    public var avatar: Avatar

    public init(displayName: String, avatar: Avatar) {
        self.displayName = displayName
        self.avatar = avatar
    }

    public func validate() throws {
        try Validation.requireText(displayName, maxLength: Self.maxNameLength, field: "displayName")
        if let emoji = avatar.emoji, !Validation.isSingleEmoji(emoji) {
            throw CryptoError.invalidPayload("avatar.emoji")
        }
    }
}

public struct Avatar: Hashable, Sendable, Codable {
    /// Shown instead of initials when set. Must be a single emoji.
    public var emoji: String?
    public var color: AvatarColor

    public init(emoji: String?, color: AvatarColor) {
        self.emoji = emoji
        self.color = color
    }
}

public enum AvatarColor: String, CaseIterable, Hashable, Sendable, Codable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink

    /// Colors added by newer app versions decode as blue instead of failing the whole profile.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = AvatarColor(rawValue: rawValue) ?? .blue
    }
}

// MARK: - Location

/// One location update, as shared with a friend.
public struct SharedLocation: SealablePayload, Hashable {
    public static let kind = PayloadKind.location

    public var latitude: Double
    public var longitude: Double
    /// Radius of uncertainty, in meters.
    public var horizontalAccuracy: Double
    /// True when the sharer has Precise Location turned off.
    public var isApproximate: Bool
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, isApproximate: Bool, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.isApproximate = isApproximate
        self.timestamp = timestamp
    }

    public func validate() throws {
        try Validation.requireCoordinate(latitude: latitude, longitude: longitude)
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else {
            throw CryptoError.invalidPayload("horizontalAccuracy")
        }
    }
}

// MARK: - Alerts

public enum AlertTrigger: String, Sendable, Codable, CaseIterable {
    case arrive
    case leave
}

/// "Notify me when you arrive at/leave this place", sent by the requester to the person being watched.
public struct AlertRequest: SealablePayload, Hashable {
    public static let kind = PayloadKind.alertRequest
    public static let radiusRange: ClosedRange<Double> = 100...5_000
    public static let maxPlaceNameLength = 60
    public static let maxIdLength = 64

    /// Matches the Firestore document ID, so the server can't swap one request's contents for another's.
    public var id: String
    public var placeName: String
    public var latitude: Double
    public var longitude: Double
    /// Geofence radius in meters.
    public var radius: Double
    public var trigger: AlertTrigger

    public init(id: String, placeName: String, latitude: Double, longitude: Double, radius: Double, trigger: AlertTrigger) {
        self.id = id
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.trigger = trigger
    }

    public func validate() throws {
        try Validation.requireText(id, maxLength: Self.maxIdLength, field: "id")
        try Validation.requireText(placeName, maxLength: Self.maxPlaceNameLength, field: "placeName")
        try Validation.requireCoordinate(latitude: latitude, longitude: longitude)
        guard Self.radiusRange.contains(radius) else {
            throw CryptoError.invalidPayload("radius")
        }
    }
}

/// Sent by the watched person's device to the requester when an alert fires.
public struct AlertEvent: SealablePayload, Hashable {
    public static let kind = PayloadKind.alertEvent

    public var alertId: String
    public var placeName: String
    public var trigger: AlertTrigger
    public var occurredAt: Date

    public init(alertId: String, placeName: String, trigger: AlertTrigger, occurredAt: Date) {
        self.alertId = alertId
        self.placeName = placeName
        self.trigger = trigger
        self.occurredAt = occurredAt
    }

    public func validate() throws {
        try Validation.requireText(alertId, maxLength: AlertRequest.maxIdLength, field: "alertId")
        try Validation.requireText(placeName, maxLength: AlertRequest.maxPlaceNameLength, field: "placeName")
    }
}

// MARK: - Validation

enum Validation {
    static func requireText(_ text: String, maxLength: Int, field: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxLength else {
            throw CryptoError.invalidPayload(field)
        }
    }

    static func requireCoordinate(latitude: Double, longitude: Double) throws {
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            throw CryptoError.invalidPayload("coordinate")
        }
    }

    /// One grapheme that renders as an emoji. Plain digits and `#` have the Unicode Emoji
    /// property too, so require emoji presentation or the emoji variation selector.
    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1 else { return false }
        return text.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar == "\u{FE0F}"
        }
    }
}
