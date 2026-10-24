//
//  CommunitySearchArea.swift
//  OpenHikes
//
//  The piece of map a nearby answer is about: a circle, and — when the map
//  asked — the rectangle of it the hiker could see.
//
//  Its own value type rather than a loose coordinate-and-radius pair because
//  three separate things now have to agree about one area: the offer the map
//  makes (*Search this area*), the request the transport sends, and the place
//  name the list is headed with. While those were three arguments passed
//  around separately, the question the hiker confirmed and the question that
//  was asked could differ by a pan that landed in between.
//
//  Stored as two `Double`s rather than as a `CLLocationCoordinate2D`, for the
//  reason ``CommunityListing`` stores its own that way: the Core Location
//  type is neither `Equatable` nor `Hashable`, and this value is compared —
//  by ``CommunityQueryPolicy``, to decide whether the map is asking something
//  new, and by `@Observable`, which filters a same-value write only for an
//  `Equatable` type. See *Render isolation, in practice*.
//
//  ## Two shapes, because there are two servers
//
//  CloudKit's `distanceToLocation:` takes a circle and resolves at around ten
//  kilometres, so the published half asks ``radiusMeters``, floored where the
//  server stops telling distances apart. Overpass takes a box and answers it
//  exactly, so the OpenStreetMap half asks about ``visibleSpan`` — the map
//  above the sheet, as wide and as tall as it is. It used to be asked about
//  the square around the circle instead, floored at twenty kilometres a side:
//  measured on 2026-10-21, that was 4.8 times the map above a half-height
//  sheet at any zoom and seventeen times it at a five-kilometre view, and the
//  rows nearest its centre were the trails under the sheet.
//

import CoreLocation
import Foundation
import OpenHikesData

/// A place and a distance around it: what one nearby request covers.
nonisolated struct CommunitySearchArea: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// How far out from the centre the question reaches, in metres. Clamped
    /// by ``CommunityQueryPolicy`` before it ever gets here — see the
    /// minimum and maximum there for why neither bound is the map's own.
    var radiusMeters: Double
    /// The rectangle of map the hiker could see when the question was put,
    /// centred on ``coordinate`` — or `nil` for an area that is only a circle.
    ///
    /// What OpenStreetMap is asked about — see this file's header and
    /// ``CuratedTrailQuery/searchBoxes(for:)`` — by the *Community* tab and
    /// by every place search a *Search this area* pill makes, which
    /// ``TrailPointFinder`` builds from the same measurement of the map. The
    /// photographs Wikimedia Commons answers with for either are kept inside
    /// it too — see ``CommonsAreaPhotos``.
    /// `nil` for every area the map did not hand over — a stretch of a route,
    /// the reach around a fix, *Places Nearby*'s first question — and those
    /// keep the square around the circle.
    var visibleSpan: Span?

    init(coordinate: CLLocationCoordinate2D, radiusMeters: Double, visibleSpan: Span? = nil) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.radiusMeters = radiusMeters
        self.visibleSpan = visibleSpan
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated extension CommunitySearchArea {
    /// How tall and how wide a rectangle is, in degrees, edge to edge —
    /// `MKCoordinateSpan`'s two numbers, held here because MapKit's type is not
    /// `Equatable` and this one has to be. See this file's header.
    struct Span: Equatable, Sendable {
        var latitudeDelta: Double
        var longitudeDelta: Double
    }

    /// Whether `point` stands in this area: inside ``visibleSpan`` when the
    /// area carries one, and within ``radiusMeters`` of its centre when it
    /// does not.
    ///
    /// The rectangle wins for the reason it is what OpenStreetMap is asked
    /// about. What this answers is which of the things already on the device
    /// a refused search draws — see ``OverpassFileStore`` — and those have to
    /// be in the map the hiker could see, not in the circle floored for
    /// CloudKit, which at a valley's zoom reaches well past the screen and
    /// under the sheet. Longitude is compared the short way round, so a view
    /// across the date line holds what stands on both sides of it.
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        guard let visibleSpan else {
            return RouteGeometry.distanceMeters(from: coordinate, to: point) <= radiusMeters
        }
        let east = RouteGeometry.normalizedLongitudeDelta(point.longitude - longitude)
        return abs(point.latitude - latitude) <= visibleSpan.latitudeDelta / 2
            && abs(east) <= visibleSpan.longitudeDelta / 2
    }
}
