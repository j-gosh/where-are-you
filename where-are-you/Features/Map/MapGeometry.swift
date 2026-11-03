//
//  MapGeometry.swift
//  where-are-you
//

import MapKit

enum MapGeometry {
    /// The smallest rect containing every coordinate, at least `minimumMeters` across,
    /// padded by `paddingFraction` of its size on each side. `nil` when there are no coordinates.
    ///
    /// Doesn't wrap around the antimeridian, so Tokyo + Los Angeles frames the long way round.
    static func rect(
        enclosing coordinates: [CLLocationCoordinate2D],
        paddingFraction: Double = 0.2,
        minimumMeters: Double = 1_000
    ) -> MKMapRect? {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return nil }

        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let minimumSize = minimumMeters * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude)
        let width = max(maxX - minX, minimumSize)
        let height = max(maxY - minY, minimumSize)
        let padX = width * paddingFraction
        let padY = height * paddingFraction
        return MKMapRect(
            x: (minX + maxX) / 2 - width / 2 - padX,
            y: (minY + maxY) / 2 - height / 2 - padY,
            width: width + 2 * padX,
            height: height + 2 * padY
        )
    }

    /// A region that shows `coordinate` in the middle of the part of the map not covered
    /// by a bottom sheet taking up `coveredFraction` of the height.
    static func region(
        focusing coordinate: CLLocationCoordinate2D,
        spanMeters: Double = 2_000,
        coveredFraction: Double = 0
    ) -> MKCoordinateRegion {
        let base = MKCoordinateRegion(center: coordinate, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
        let shift = base.span.latitudeDelta * coveredFraction / 2
        let center = CLLocationCoordinate2D(latitude: max(coordinate.latitude - shift, -85), longitude: coordinate.longitude)
        return MKCoordinateRegion(center: center, span: base.span)
    }
}
