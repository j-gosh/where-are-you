//
//  MapAndFormattingTests.swift
//  where-are-youTests
//

import CoreLocation
import Foundation
import MapKit
import Testing
import WAYCore
@testable import where_are_you

struct MapGeometryTests {
    private let losAngeles = CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24)
    private let newYork = CLLocationCoordinate2D(latitude: 40.71, longitude: -74.0)

    @Test func noCoordinatesGivesNoRect() {
        #expect(MapGeometry.rect(enclosing: []) == nil)
    }

    @Test func rectContainsEveryCoordinate() throws {
        let rect = try #require(MapGeometry.rect(enclosing: [losAngeles, newYork]))

        #expect(rect.contains(MKMapPoint(losAngeles)))
        #expect(rect.contains(MKMapPoint(newYork)))
    }

    @Test func singleCoordinateGetsMinimumSize() throws {
        let rect = try #require(MapGeometry.rect(enclosing: [losAngeles], paddingFraction: 0, minimumMeters: 1_000))
        let expected = 1_000 * MKMapPointsPerMeterAtLatitude(losAngeles.latitude)

        #expect(abs(rect.width - expected) < 0.001)
        #expect(abs(rect.height - expected) < 0.001)
        #expect(rect.contains(MKMapPoint(losAngeles)))
    }

    @Test func focusedRegionShiftsCenterBelowCoordinateForSheet() {
        let region = MapGeometry.region(focusing: losAngeles, spanMeters: 2_000, coveredFraction: 0.5)

        #expect(region.center.latitude < losAngeles.latitude)
        #expect(region.center.longitude == losAngeles.longitude)
        // The coordinate sits in the middle of the uncovered top half.
        let topEdge = region.center.latitude + region.span.latitudeDelta / 2
        let expectedLatitude = topEdge - region.span.latitudeDelta / 4
        #expect(abs(expectedLatitude - losAngeles.latitude) < 1e-9)
    }

    @Test func focusedRegionWithoutSheetIsCentered() {
        let region = MapGeometry.region(focusing: losAngeles)

        #expect(region.center.latitude == losAngeles.latitude)
    }
}

struct FormattingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let locale = Locale(identifier: "en_US")

    private func location(minutesAgo: Double, latitude: Double = 0, longitude: Double = 0) -> SharedLocation {
        SharedLocation(latitude: latitude, longitude: longitude, horizontalAccuracy: 10, isApproximate: false, timestamp: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func staleAfterAnHour() {
        #expect(!location(minutesAgo: 59).isStale(at: now))
        #expect(location(minutesAgo: 61).isStale(at: now))
    }

    @Test func recentUpdateSaysNow() {
        #expect(LocationFormatting.lastUpdated(now.addingTimeInterval(-20), now: now, locale: locale) == "Now")
    }

    @Test func olderUpdateIsRelative() {
        let text = LocationFormatting.lastUpdated(now.addingTimeInterval(-5 * 60), now: now, locale: locale)
        #expect(text.contains("5"))
        #expect(text.contains("ago"))
    }

    @Test func distanceNeedsUserLocation() {
        #expect(LocationFormatting.distance(from: nil, to: location(minutesAgo: 1)) == nil)
    }

    @Test func distanceUsesLocaleUnits() throws {
        let user = UserLocation(latitude: 0, longitude: 0, horizontalAccuracy: 5, timestamp: now)
        let text = try #require(LocationFormatting.distance(from: user, to: location(minutesAgo: 1, latitude: 0.1), locale: locale))
        #expect(text.contains("mi"))
    }

    @Test(arguments: [
        ("Olivia Bennett", "OB"),
        ("Cher", "C"),
        ("", "?"),
    ])
    func initials(name: String, expected: String) {
        #expect(AvatarView.initials(for: name) == expected)
    }
}
