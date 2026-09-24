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
//  ## The names are plausible rather than obviously fake, and that is deliberate
//
//  They read as ordinary Bavarian trail names — the places are real features
//  near where these two sit — because these rows are what the App Store
//  screenshot of the nearby list is made of, and a listing showing "Seeded
//  Valley Path" tells a reader they are looking at test data. They are still
//  invented: no OpenStreetMap relation carries these ids or these tags. See
//  `Screenshots/README.md`.
//
//  Both sit about eight kilometres from ``UITestFixture``'s trailhead, where
//  the scenarios put the simulated fix — inside the smallest search this
//  feature allows (``CommunityQueryPolicy/minimumRadiusMeters``), so a nearby
//  search finds them beside the seeded published hikes rather than instead of
//  them.
//
//  **Eight kilometres and not a few hundred metres, which is what this said
//  and was believed.** The merged answer is sorted nearest first across both
//  halves, so the distance is what decides where a curated row lands: at this
//  range both sort behind all three seeded published hikes, which puts the
//  second of them past the fold of a sheet at its middle detent. That is not
//  a fault in the fixture — a list of twenty-five is past the fold whatever
//  the order — but it is the reason a wait that only asked whether a row
//  existed reported that the curated half had never answered. See
//  ``XCTestCase/awaitCommunityAnswer(_:in:)``.
//

import CoreLocation
import Foundation
import OpenHikesData

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
    /// Internal rather than private, because ``SeededCommunityTransport``
    /// hangs a contributed set of photographs on this route: a trail
    /// OpenStreetMap has no picture of, with three of somebody's, is the
    /// headline case of the whole contribution feature and the only way a
    /// launch can reach it.
    static let loopRelationID: Int64 = 4_811_001
    private static let openRelationID: Int64 = 4_811_002
    /// About 670 m of latitude and a little less of longitude at this latitude,
    /// which puts the loop at roughly 2.6 km and the open route at about 4 km.
    ///
    /// It was a tenth of this, and a row then read "350 m · Loop" — which is
    /// not a walk, and which the App Store screenshot of this list had to say
    /// out loud. The size has a second effect worth keeping: the map frames
    /// itself to whatever it is showing, and at the old scale that framing
    /// landed inside a single OpenStreetMap forest tile — a flat green
    /// rectangle with tree glyphs on it, which is what the screenshot showed
    /// instead of terrain.
    ///
    /// Still far inside ``CuratedTrailQuery/maximumSpanMeters``, so both
    /// routes survive the day-hike filter exactly as they did before.
    private static let step = 0.006
    /// Multiples of ``step`` the open route's four points are spaced by, so
    /// its two ends are far enough apart to read as point-to-point rather
    /// than as a loop that failed to close.
    private static let openRouteSpacing: [(Double, Double)] = [
        (0, 0), (2, 1), (4, 2), (6, 3),
    ]

    func listings(near area: CommunitySearchArea, limit: Int) -> [CuratedTrail] {
        // The area is deliberately ignored, exactly as the seeded published
        // transport ignores it: what a scenario is asking is what the list
        // does with these rows, and making that depend on where the
        // simulator's map settled would turn a UI assertion into a geography
        // assertion — the failure being an empty list with nothing to say
        // about why.
        Array(Self.seededTrails.prefix(max(0, limit)))
    }

    /// Already complete, because these two never went over a wire.
    ///
    /// The split between listing and geometry is about what a request costs,
    /// and nothing here makes one. What a scenario still exercises is the
    /// *shape* of the split — the real ``MergedCommunityTransport`` decides
    /// how many rows to ask about and this answers about exactly those.
    func completed(_ listed: [CuratedTrail]) -> CuratedCompletion {
        CuratedCompletion(trails: listed)
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

    func trails(of relationIDs: [Int64]) -> [Int64: CuratedTrail] {
        let wanted = Set(relationIDs)
        return Dictionary(
            uniqueKeysWithValues: Self.seededTrails
                .filter { wanted.contains($0.relationID) }
                .map { ($0.relationID, $0) }
        )
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
            name: "Lattenberg Rundweg",
            tags: [
                "name": "Lattenberg Rundweg",
                "route": "hiking",
                "network": "lwn",
                "ref": "7",
                "osmc:symbol": "red:red:white_bar:7:black",
                "roundtrip": "yes",
                "from": "Schwarzbachwacht",
                "to": "Schwarzbachwacht",
                "via": "Steinerne Agnes",
                "operator": "Deutscher Alpenverein",
                "website": "https://example.org/lattenberg-rundweg",
                "description": "Schwarzbachwacht - Steinerne Agnes - Schwarzbachwacht",
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
            name: "Schwarzbach Steig",
            tags: [
                "name": "Schwarzbach Steig",
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

/// Heights for the two seeded routes, so the profile a curated hike now draws
/// is reachable from automation.
///
/// Behind the same door and for the same reason as the source above: the
/// shape of the answer is real — one height per point asked about, in order —
/// and only the network is not. A run that opens a seeded curated hike draws
/// the real ``ElevationChartView`` from a real ``RouteProfile`` built by the
/// real ``CuratedElevationSourcing/filled(_:)``.
nonisolated struct SeededElevationSource: CuratedElevationSourcing {
    /// A valley at 600 m with a 120 m climb over the route, which is enough
    /// relief for a chart to have a shape and for a scrub to read differently
    /// at either end.
    private static let baseMeters = 600.0
    private static let climbMeters = 120.0

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
        let last = Double(max(coordinates.count - 1, 1))
        return coordinates.indices.map { index in
            Self.baseMeters + Self.climbMeters * sin(Double(index) / last * .pi)
        }
    }
}

#endif
