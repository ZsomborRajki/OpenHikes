//
//  CommunitySearchArea.swift
//  OpenHikes
//
//  The circle of map a nearby answer is about.
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

import CoreLocation
import Foundation

/// A place and a distance around it: what one nearby request covers.
nonisolated struct CommunitySearchArea: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// How far out from the centre the question reaches, in metres. Clamped
    /// by ``CommunityQueryPolicy`` before it ever gets here — see the
    /// minimum and maximum there for why neither bound is the map's own.
    var radiusMeters: Double

    init(coordinate: CLLocationCoordinate2D, radiusMeters: Double) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.radiusMeters = radiusMeters
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
