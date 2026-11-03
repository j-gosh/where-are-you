//
//  AddressLookup.swift
//  where-are-you
//

import CoreLocation
import MapKit
import SwiftUI

protocol AddressLookup: Sendable {
    /// A short single-line address for the coordinate, or `nil` if there isn't one (open sea, ...).
    func address(latitude: Double, longitude: Double) async throws -> String?
}

/// Reverse geocodes with Apple's servers. Apple rate-limits this, so callers should
/// only look up addresses the user is actually looking at.
struct GeocoderAddressLookup: AddressLookup {
    func address(latitude: Double, longitude: Double) async throws -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            let address = try await request.mapItems.first?.address
            return address?.shortAddress ?? address?.fullAddress
        }
        #endif
        guard let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var parts = [placemark.name].compactMap { $0 }
        if let locality = placemark.locality, !parts.contains(locality) {
            parts.append(locality)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension EnvironmentValues {
    @Entry var addressLookup: any AddressLookup = GeocoderAddressLookup()
}
