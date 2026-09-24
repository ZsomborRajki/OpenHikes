//
//  HikePlaceCard.swift
//  OpenHikes
//
//  What a saved hike's place screen says about one place, worked out from the
//  hike as it is now.
//
//  A value apart from ``HikePlaceView`` for the reason ``TrailPlaceCard`` is
//  one apart from the maker's sheet: which line is the title, what the
//  subtitle says and whether the hiker may edit the place are decisions, and a
//  decision inside a body is one only a UI test can check.
//

import CoreLocation
import SwiftUI

struct HikePlaceCard: Equatable {
    var place: TrailPlace
    var title: String
    var subtitle: String?
    /// How far along the trail it sits, when that can be said — see
    /// ``TrailPlaceAnchor``.
    var distanceAlongRouteMeters: Double?
    var facts: [TrailPlaceFact]
    var openStreetMapURL: URL?
    /// Whether the hiker may rename, re-kind and annotate it — only a place
    /// that is their own. See ``TrailPlace/isHikersOwn``.
    var isEditable: Bool

    var systemImage: String { place.systemImageName }
    var tint: Color { place.tint }
    var coordinate: CLLocationCoordinate2D { place.clCoordinate }
    var note: String { place.note }

    /// Where it came from, in words: the second half of what the card says
    /// about who may change it.
    var provenance: String {
        isEditable
            ? String(localized: "Added by you")
            : String(localized: "From OpenStreetMap")
    }

    /// `nil` for a place the hike no longer has — removed here, or on another
    /// device — which closes the screen.
    @MainActor
    init?(hike: Hike, placeID: UUID) {
        guard let row = hike.placeRow(id: placeID) else { return nil }
        self.init(row: row)
    }

    init(row: TrailPlaceRow) {
        place = row.place
        title = row.place.displayName
        distanceAlongRouteMeters = row.anchor?.distanceAlongRouteMeters
        // The kind is left out when it is already the title, as the maker's
        // card does, so an unnamed spring does not read "Water · Water".
        subtitle = TrailPlaceCard.subtitle(
            kind: row.place.name.isEmpty ? nil : row.place.symbol?.label,
            distance: row.anchor?.distanceAlongRouteMeters
        )
        facts = row.place.osm?.facts ?? []
        openStreetMapURL = row.place.osm?.url
        isEditable = row.place.isHikersOwn
    }
}
