//
//  PlacesNearbyFrame.swift
//  OpenHikes
//
//  Where *Places Nearby* points the map when it opens, and so what its first
//  search asks about: the walk recorded so far and where the hiker is now,
//  with room around both — see ``HikePlacesNearbyView``.
//
//  Never narrower than ``minimumSpanMeters``, because the first minutes of a
//  walk are a line a few hundred metres long, and *what is around me* is not
//  answered by the width of a car park. Never wider than one search can ask
//  about: a day's walk framed whole can be thirty kilometres across, which
//  ``TrailPointQuery/maximumRadiusMeters`` refuses, so a line that long gives
//  way to the hiker's own surroundings — the question the screen exists for.
//

import CoreLocation
import MapKit
import OpenHikesData

enum PlacesNearbyFrame {
    /// The narrowest frame, across either side.
    static let minimumSpanMeters: CLLocationDistance = 2000

    /// Room around the line, as ``MapController/showDrawnLine(_:)`` leaves,
    /// so the ends of the walk are inside the frame rather than on its edge.
    static let padding = 1.4

    /// The region to show and search, or `nil` with neither a walk nor a
    /// position to frame — a recording that has not had its first fix.
    static func region(
        line: [CLLocationCoordinate2D],
        position: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion? {
        var points = line
        if let position { points.append(position) }
        guard let focus = position ?? points.last else { return nil }
        let framed = fitted(points)
        guard CommunityQueryPolicy.visibleRadiusMeters(for: framed) <= TrailPointQuery.maximumRadiusMeters else {
            return fitted([focus])
        }
        return framed
    }

    /// The circle the first search asks about, before the camera has arrived
    /// at `region`.
    ///
    /// A circle with no rectangle, so Overpass is asked about the square
    /// around it. The camera fits `region` into the map above the sheet's
    /// middle detent, which on a phone is about as tall as it is wide, so
    /// that square is about the map the hiker sees once the camera arrives —
    /// the map *Search This Area* asks about after that, see
    /// ``TrailPointFinder/regionDidSettle(_:)``. A rectangle of the frame's
    /// own would be the narrower question whenever the walk runs further one
    /// way than the other, leaving the map either side of it unasked.
    static func area(of region: MKCoordinateRegion) -> CommunitySearchArea {
        CommunitySearchArea(
            coordinate: region.center,
            radiusMeters: CommunityQueryPolicy.visibleRadiusMeters(for: region)
        )
    }

    /// `points` padded, and widened to the minimum. MapKit's own bounds rather
    /// than four `min`/`max`es, for the antimeridian reason
    /// ``MapController/showDrawnLine(_:)`` gives.
    private static func fitted(_ points: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var coordinates = points
        let bounds = MKCoordinateRegion(
            MKPolyline(coordinates: &coordinates, count: coordinates.count).boundingMapRect
        )
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        let latitudeMeters = bounds.span.latitudeDelta * metersPerDegree * padding
        let longitudeMeters = bounds.span.longitudeDelta * metersPerDegree
            * cos(bounds.center.latitude * .pi / 180) * padding
        return MKCoordinateRegion(
            center: bounds.center,
            latitudinalMeters: max(latitudeMeters, minimumSpanMeters),
            longitudinalMeters: max(longitudeMeters, minimumSpanMeters)
        )
    }
}
