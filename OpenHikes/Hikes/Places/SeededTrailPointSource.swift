//
//  SeededTrailPointSource.swift
//  OpenHikes
//
//  Three places on the Thumsee loop that nobody asked Overpass for.
//
//  ``OpenHikesModel/makeTrailPointSource()`` hands back `nil` for every launch
//  running tests, and rightly: the real source reaches a volunteer-run public
//  API. But that `nil` also removes *Find Places Along Trail* from a saved
//  hike and *Mapped Here* from the recording screen's *Add Place*, so neither
//  had ever been in front of an accessibility audit — and the refusal copy a
//  hiker reads when Overpass says no was reachable by nothing at all.
//
//  This is the third answer between "the real API" and "nothing", on the terms
//  ``SeededCommunityTransport`` set: a launch gets one only by naming a
//  scenario — `--ui-test-trail-points=<seeded|refused>` — and the whole file
//  is `#if DEBUG`, so no build a person could install contains it.
//
//  ## What is faked, and what is not
//
//  Only the network. ``TrailPlaceCorridorSearch`` still cuts the line into
//  stretches, keeps what the line passes and drops what the hike already
//  holds; ``NearbyPlaceSuggestions`` still measures what is within reach of
//  the fix. So a place below that is not on the line, or not near the
//  trailhead, is dropped by the shipping code — which is why the coordinates
//  are points of the `ThumseeLoopPlaces` fixture's own track.
//
//  ## What the three are shaped for
//
//  - Two within ``NearbyPlaceSuggestions/matchRadiusMeters`` of the trailhead,
//    which is where the recording scenarios stand, so *Mapped Here* has rows.
//    Both are more than 25 m from the fixture's *Boathouse*, which stands on
//    the trailhead, so the search along the trail does not fold them into it.
//  - One unnamed, so a row drawn from the kind alone is swept too.
//  - One far enough along to be in the search sheet and not the recording one.
//

import Foundation

#if DEBUG

/// A stand-in for Overpass with three places on the Thumsee loop.
nonisolated struct SeededTrailPointSource: TrailPointSourcing {
    enum Scenario: String, CaseIterable {
        /// The three places below, whatever is asked.
        case seeded = "seeded"
        /// Every search is refused, so the copy a hiker reads when Overpass
        /// cannot be reached is on screen.
        case refused = "refused"

        /// The scenario a launch argument names, or `nil` for a launch that
        /// did not ask — which is every launch that must get no source at all.
        init?(argument: String?) {
            guard let argument, let named = Self(rawValue: argument) else { return nil }
            self = named
        }
    }

    let scenario: Scenario

    /// Points of the fixture's own track, so the corridor search keeps them:
    /// the first two about 65 m and 110 m from the trailhead, the third a
    /// kilometre on.
    private static let carParkSpot = (latitude: 47.718823, longitude: 12.831149)
    private static let viewpointSpot = (latitude: 47.719219, longitude: 12.830877)
    private static let hutSpot = (latitude: 47.724008, longitude: 12.829098)
    /// Element ids no real OpenStreetMap element has, so a seeded place can
    /// never be mistaken for a fetched one on a saved hike.
    private static let carParkID: Int64 = 9_100_001
    private static let viewpointID: Int64 = 9_100_002
    private static let hutID: Int64 = 9_100_003

    static let places: [TrailPlace] = [
        TrailPlace(
            latitude: carParkSpot.latitude,
            longitude: carParkSpot.longitude,
            name: "Thumsee Car Park",
            symbol: .parking,
            osm: TrailPlaceOSM(
                elementType: "way",
                elementID: carParkID,
                facts: [TrailPlaceFact(kind: .fee, value: "yes")]
            )
        ),
        TrailPlace(
            latitude: viewpointSpot.latitude,
            longitude: viewpointSpot.longitude,
            symbol: .viewpoint,
            osm: TrailPlaceOSM(
                elementType: "node",
                elementID: viewpointID,
                facts: [TrailPlaceFact(kind: .elevation, value: "532")]
            )
        ),
        TrailPlace(
            latitude: hutSpot.latitude,
            longitude: hutSpot.longitude,
            name: "Lakeshore Hut",
            symbol: .shelter,
            osm: TrailPlaceOSM(
                elementType: "node",
                elementID: hutID,
                facts: [
                    TrailPlaceFact(kind: .elevation, value: "540"),
                    TrailPlaceFact(kind: .openingHours, value: "May-Oct 10:00-18:00"),
                ]
            )
        ),
    ]

    /// The area is ignored, as ``SeededCuratedTrailSource`` ignores it: the
    /// searches above it already decide what is near enough, and making the
    /// answer depend on where a stretch's box happened to fall would turn a
    /// screen assertion into a geometry one.
    func places(near area: CommunitySearchArea, showing symbols: Set<TrailPlaceSymbol>) throws -> [TrailPlace] {
        switch scenario {
        case .seeded:
            return Self.places.filter { place in place.symbol.map(symbols.contains) ?? true }
        case .refused:
            throw URLError(.notConnectedToInternet)
        }
    }
}

#endif
