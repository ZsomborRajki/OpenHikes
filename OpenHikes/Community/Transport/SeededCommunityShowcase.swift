//
//  SeededCommunityShowcase.swift
//  OpenHikes
//
//  The nearby list the App Store frame of the Community tab is made of,
//  behind `--ui-test-community=showcase`.
//
//  The seeded scenarios are shaped for the suites that assert on them: lines
//  generated in straight steps, and waymarked routes drawn as a square and a
//  zigzag, so a test can predict every length and every row. On a map full of
//  real paths that reads as exactly what it is — test data — and a store
//  listing is the one place it must not. So the frame gets a scenario of its
//  own rather than a reshaped fixture under the suites' feet.
//
//  Everything here follows a line mapped on the ground, around the Königssee
//  where the rest of the set is staged:
//
//  - **Two published walks**, by the seeded transport's two invented hikers.
//    *Kührointalm and Back* is the opening five kilometres of the hero
//    frame's own fixture, up to the alm and down the same way; *Malerwinkel
//    Loop* is OpenStreetMap relation 2428487, the lakeside circuit at the
//    landing. The people are made up and say so nowhere, as in every
//    scenario; the paths are not.
//  - **Two waymarked routes**, which *are* OpenStreetMap's — relations 193469
//    and 222506, under their own ids and with the tags the map carries, which
//    is what lets a row draw the red-white-red blaze and the two ends a
//    signpost names. The other seeded routes have ids no relation has, so a
//    run cannot be confused with a fetched one; these are fetched ones,
//    frozen, so the id is the right one to keep.
//
//  The lines are bundled as GPX beside the other fixtures in
//  `SimulatedLocations/`, each carrying the ODbL notice, and like them are
//  left out of a Release build.
//

import CoreLocation
import Foundation
import OpenHikesData

#if DEBUG

nonisolated extension SeededCommunityTransport {
    static let showcaseKuehrointTitle = "Kührointalm and Back"
    static let showcaseMalerwinkelTitle = "Malerwinkel Loop"

    /// How far up the hero fixture *Kührointalm and Back* turns round: the
    /// alm, at the top of the climb from the landing.
    private static let kuehrointTurnMeters = 5000.0

    /// The listings `scenario` answers with.
    static func listings(servedBy scenario: Scenario) -> [CommunityListing] {
        scenario == .showcase ? showcaseListings : seededListings
    }

    /// The line a showcase walk follows, or nothing for every other listing.
    static func showcaseRoute(of listing: CommunityListing) -> [RouteCoordinate] {
        showcaseRoutes[listing.id] ?? []
    }

    /// Anna's walk up to the alm, with photographs, and Bern's lakeside loop.
    static let showcaseListings: [CommunityListing] = [
        showcaseListing(
            id: "showcase-listing-kuehroint",
            title: showcaseKuehrointTitle,
            authorID: blockableAuthorID,
            authorName: blockableAuthorName,
            photoCount: photographedCount
        ),
        showcaseListing(
            id: "showcase-listing-malerwinkel",
            title: showcaseMalerwinkelTitle,
            authorID: otherAuthorID,
            authorName: "Bern",
            photoCount: 0
        ),
    ].compactMap(\.self)

    private static let showcaseRoutes: [String: [RouteCoordinate]] = [
        "showcase-listing-kuehroint": outAndBack(
            bundledRoute("KoenigsseeRinnkendlsteig"),
            turningAt: kuehrointTurnMeters
        ),
        "showcase-listing-malerwinkel": bundledRoute("KoenigsseeMalerwinkel"),
    ].filter { !$0.value.isEmpty }

    private static func showcaseListing(
        id: String,
        title: String,
        authorID: String,
        authorName: String,
        photoCount: Int
    ) -> CommunityListing? {
        guard let route = showcaseRoutes[id], let start = route.first else { return nil }
        return CommunityListing(
            id: id,
            submissionID: "\(id)-submission",
            title: title,
            authorName: authorName,
            authorID: authorID,
            hikeDate: hikeDate,
            distanceMeters: SeededCuratedTrailSource.length(of: route),
            photoCount: photoCount,
            latitude: start.latitude,
            longitude: start.longitude,
            publishedAt: publishedDate
        )
    }

    /// `route` as far as `meters`, then back the way it came — the walk a
    /// hiker who turns round at the top publishes. The way down keeps the way
    /// up's heights and spends as long as it took, which is generous to the
    /// descent and makes no difference to anything this frame shows.
    private static func outAndBack(_ route: [RouteCoordinate], turningAt meters: Double) -> [RouteCoordinate] {
        var walked = 0.0
        var outward: [RouteCoordinate] = []
        for point in route {
            if let previous = outward.last {
                walked += RouteGeometry.distanceMeters(from: previous.clCoordinate, to: point.clCoordinate)
                guard walked <= meters else { break }
            }
            outward.append(point)
        }
        guard let turn = outward.last?.timestamp else { return outward }
        let back = outward.reversed().dropFirst().map { point in
            var returning = point
            returning.timestamp = point.timestamp.map { turn.addingTimeInterval(turn.timeIntervalSince($0)) }
            return returning
        }
        return outward + back
    }

    static func bundledRoute(_ name: String) -> [RouteCoordinate] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gpx"),
              let track = try? GPXImport.load(from: url) else { return [] }
        return track.route
    }
}

nonisolated extension SeededCuratedTrailSource {
    /// AV Weg 493, Königssee – Gotzenalm – Landtal, and AV Weg 444,
    /// Hammerstiel – Stubenalm – Watzmannhaus: the relations' own ids.
    static let gotzenalmRelationID: Int64 = 193_469
    static let watzmannhausRelationID: Int64 = 222_506

    /// Two of the waymarked routes OpenStreetMap has around the Königssee,
    /// under their own relation ids and with their own tags.
    static let showcaseTrails: [CuratedTrail] = [
        showcaseTrail(
            relationID: gotzenalmRelationID,
            fixture: "KoenigsseeGotzenalm",
            tags: [
                "name": "AV Weg 493 (Königssee - Gotzenalm - Landtal)",
                "route": "hiking",
                "network": "lwn",
                "ref": "493",
                "osmc:symbol": "red:red:white_bar:493:black",
                "operator": "Deutscher Alpenverein",
                "description": "Königssee - Gotzenalm - Landtal",
            ]
        ),
        showcaseTrail(
            relationID: watzmannhausRelationID,
            fixture: "HammerstielWatzmannhaus",
            tags: [
                "name": "AV Weg 444",
                "route": "hiking",
                "network": "lwn",
                "ref": "444",
                "osmc:symbol": "red:red:white_bar:444:black",
                "operator": "DAV Sektion Berchtesgaden",
                "description": "Hammerstiel - Stubenalm - Watzmannhaus",
            ]
        ),
    ].compactMap(\.self)

    private static func showcaseTrail(
        relationID: Int64,
        fixture: String,
        tags: [String: String]
    ) -> CuratedTrail? {
        let route = SeededCommunityTransport.bundledRoute(fixture)
        let latitudes = route.map(\.latitude)
        let longitudes = route.map(\.longitude)
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else { return nil }
        return CuratedTrail(
            relationID: relationID,
            name: tags["name"] ?? "",
            tags: tags,
            box: CuratedTrailQuery.BoundingBox(south: south, west: west, north: north, east: east),
            route: route
        )
    }

    /// The length along `route`, which is what a published walk's row prints.
    static func length(of route: [RouteCoordinate]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { total, leg in
            total + RouteGeometry.distanceMeters(from: leg.0.clCoordinate, to: leg.1.clCoordinate)
        }
    }
}

#endif
