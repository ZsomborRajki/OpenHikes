//
//  SeededCuratedTrailSource.swift
//  OpenHikes
//
//  Two waymarked routes that nobody fetched.
//
//  The curated half of ``SeededCommunityTransport``, and it exists for exactly
//  the same reason and behind exactly the same door: a launch gets one only by
//  naming `--ui-test-community=curated`, and the whole file is `#if DEBUG`, so
//  no shipping build contains it and no suite reaches Overpass by falling into
//  anything. See that file's header — the argument there is this file's
//  argument, one service over.
//
//  What is faked is only the network. The routes below go through the real
//  ``CuratedTrailFacts`` parser, the real ``CommunityListing/init(curated:editedAt:)``,
//  the real ``MergedCommunityTransport`` merge and limit split, the real
//  ``CommunityRouteOutline`` simplification, and the real ``CommunityImport``.
//  A test that opens one of these is testing the app.
//
//  ## What the two are shaped for
//
//  They are a pair rather than a list because the differences worth asserting
//  are differences *between* rows, and one of each is enough to have them all:
//
//  - **A loop with a waymark and both ends named.** Every row of the *On the
//    Trail* section draws, and the subtitle has all three of its parts.
//  - **A point-to-point with almost nothing on it.** `roundtrip` is absent, so
//    the shape has to be derived from the line's two ends — which is the
//    branch that is otherwise never taken — and the section shrinks to the one
//    row it has something for. A screen that has never been seen sparse is a
//    screen whose sparse state was written blind.
//
//  Both start within a few hundred metres of ``UITestFixture``'s trailhead,
//  where the scenarios put the simulated fix, so a nearby search finds them
//  beside the seeded published hikes rather than instead of them.
//

import CoreLocation
import Foundation

#if DEBUG

/// A stand-in for Overpass with two routes in it.
nonisolated struct SeededCuratedTrailSource: CuratedTrailSourcing {
    /// Near ``UITestFixture/trailheadLatitude``, so one search answers with
    /// these and the seeded published hikes together.
    private static let baseLatitude = 47.6500
    private static let baseLongitude = 12.8700
    /// Relation ids no real OSM relation has, so a seeded run can never be
    /// confused with a fetched one in a log or a saved hike's
    /// ``Hike/importedFromListingID``.
    private static let loopRelationID: Int64 = 4_811_001
    private static let openRelationID: Int64 = 4_811_002
    /// About 110 m of latitude and a little less of longitude at this
    /// latitude, which makes each leg a few hundred metres and the loop long
    /// enough to have a plausible distance on its row.
    private static let step = 0.001
    /// Multiples of ``step`` the open route's four points are spaced by, so
    /// its two ends are far enough apart to read as point-to-point rather
    /// than as a loop that failed to close.
    private static let openRouteSpacing: [(Double, Double)] = [
        (0, 0), (2, 1), (4, 2), (6, 3),
    ]

    func trails(near area: CommunitySearchArea, limit: Int) -> [CuratedTrail] {
        // The area is deliberately ignored, exactly as the seeded published
        // transport ignores it: what a scenario is asking is what the list
        // does with these rows, and making that depend on where the
        // simulator's map settled would turn a UI assertion into a geography
        // assertion — the failure being an empty list with nothing to say
        // about why.
        Array(Self.seededTrails.prefix(max(0, limit)))
    }

    func trails(matching query: String, limit: Int) -> [CuratedTrail] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !needle.isEmpty, limit > 0 else { return [] }
        return Array(
            Self.seededTrails
                .filter { $0.name.localizedLowercase.contains(needle) }
                .prefix(limit)
        )
    }

    func trail(of relationID: Int64) -> CuratedTrail? {
        Self.seededTrails.first { $0.relationID == relationID }
    }
}

// MARK: - The two routes

private extension SeededCuratedTrailSource {
    static let seededTrails: [CuratedTrail] = [loop, ridge]

    /// A closed circuit: every fact present, and `roundtrip` tagged.
    static var loop: CuratedTrail {
        // Four corners and back to the first, so the line closes exactly and
        // `roundtrip=yes` and the geometry agree.
        let points = [
            (0.0, 0.0), (step, 0.0), (step, step), (0.0, step), (0.0, 0.0),
        ]
        return trail(
            relationID: loopRelationID,
            name: "Seeded Ridge Loop",
            tags: [
                "name": "Seeded Ridge Loop",
                "route": "hiking",
                "network": "lwn",
                "ref": "7",
                "osmc:symbol": "red:red:white_bar:7:black",
                "roundtrip": "yes",
                "from": "Seeded Trailhead",
                "to": "Seeded Trailhead",
                "via": "Seeded Saddle",
                "operator": "Seeded Alpine Club",
                "website": "https://example.org/seeded-ridge-loop",
                "description": "Seeded Trailhead - Seeded Saddle - Seeded Trailhead",
            ],
            offsets: points
        )
    }

    /// An open route with no `roundtrip` tag and no waymark.
    ///
    /// The sparse case, and the one that drives
    /// ``CuratedTrailFacts/trailShape(roundtrip:route:)``'s geometry branch:
    /// its two ends are far enough apart to be point-to-point, and nothing in
    /// the tags says so.
    static var ridge: CuratedTrail {
        let points = openRouteSpacing.map { (step * $0.0, step * $0.1) }
        return trail(
            relationID: openRelationID,
            name: "Seeded Valley Path",
            tags: [
                "name": "Seeded Valley Path",
                "route": "hiking",
                "network": "lwn",
            ],
            offsets: points
        )
    }

    static func trail(
        relationID: Int64,
        name: String,
        tags: [String: String],
        offsets: [(Double, Double)]
    ) -> CuratedTrail {
        let route = offsets.map { offset in
            RouteCoordinate(
                latitude: baseLatitude + offset.0,
                longitude: baseLongitude + offset.1
            )
        }
        let latitudes = route.map(\.latitude)
        let longitudes = route.map(\.longitude)
        return CuratedTrail(
            relationID: relationID,
            name: name,
            tags: tags,
            box: CuratedTrailQuery.BoundingBox(
                south: latitudes.min() ?? baseLatitude,
                west: longitudes.min() ?? baseLongitude,
                north: latitudes.max() ?? baseLatitude,
                east: longitudes.max() ?? baseLongitude
            ),
            route: route
        )
    }
}

#endif
