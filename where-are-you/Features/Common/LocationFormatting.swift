//
//  LocationFormatting.swift
//  where-are-you
//

import CoreLocation
import Foundation
import WAYCore

enum LocationFormatting {
    /// "Now", "5 min. ago", "yesterday", ... relative to `now`.
    static func lastUpdated(_ date: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "Now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Road distance style ("2.4 mi", "350 m") in the user's units, or `nil` without a user location.
    static func distance(from user: UserLocation?, to location: SharedLocation, locale: Locale = .current) -> String? {
        guard let user else { return nil }
        let meters = CLLocation(latitude: user.latitude, longitude: user.longitude)
            .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
    }
}
