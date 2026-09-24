//
//  CommunityLinelessRowTests.swift
//  OpenHikesTests
//
//  A curated row that arrived without its line, and the one thing every place
//  that draws one has to agree about.
//
//  The row exists because the two passes behind a curated search are two
//  requests against an API that allows a handful of slots per address — see
//  `CuratedTrailSourceTests+Geometry`. The cheap pass gets through, the
//  expensive one is refused, and the page the first one paid for is now kept
//  rather than thrown away: real trails, with names, pins and what the
//  signpost says, and no length until somebody opens one.
//
//  *No length* is spelled as zero metres, because a route's length is its
//  line's length and an empty line is zero metres long. Every reader therefore
//  has to ask ``CommunityListing/drawnDistanceMeters`` rather than format the
//  field, and what is pinned here is that they do: a row saying *0 m* is a
//  claim about a trail, and it is false about every trail there is.
//
//  The list row's own subtitle is private to a SwiftUI view and is asserted
//  through the callout, which builds the same sentence from the same rule.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Community lineless row")
struct CommunityLinelessRowTests {
    private static let centre = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)

    /// A curated trail, with a line or without one. The listing pass fills in
    /// everything here except ``CuratedTrail/route``, which is the geometry
    /// pass's whole contribution.
    private static func trail(drawn: Bool) -> CuratedTrail {
        let halfSpan = 0.004
        let box = CuratedTrailQuery.BoundingBox(
            south: centre.latitude - halfSpan,
            west: centre.longitude - halfSpan,
            north: centre.latitude + halfSpan,
            east: centre.longitude + halfSpan
        )
        return CuratedTrail(
            relationID: 1234,
            name: "Soleleitensteig",
            tags: ["name": "Soleleitensteig", "route": "hiking", "roundtrip": "yes"],
            box: box,
            route: drawn
                ? [
                    RouteCoordinate(latitude: box.south, longitude: box.west),
                    RouteCoordinate(latitude: box.north, longitude: box.east),
                ]
                : []
        )
    }

    private static func listing(drawn: Bool) -> CommunityListing {
        CommunityListing(curated: trail(drawn: drawn), editedAt: .now)
    }

    /// The rule itself. Zero is not a distance a hiker can walk, and it is
    /// what an empty line measures.
    @Test("a row with no line has no distance to give")
    func aLinelessRowHasNoDistance() {
        #expect(Self.listing(drawn: false).drawnDistanceMeters == nil)
    }

    /// And the ordinary row still answers, or the rule would be a way of
    /// hiding every distance in the app.
    @Test("a row with a line reports the length of it")
    func adrawnRowKeepsItsDistance() {
        let listing = Self.listing(drawn: true)

        #expect(listing.drawnDistanceMeters == listing.distanceMeters)
        #expect((listing.drawnDistanceMeters ?? 0) > 0)
    }

    /// A published hike is never in that state: its length comes from the
    /// track whoever walked it uploaded, and it has one before it is ever
    /// listed.
    @Test("a published hike always has its distance")
    func aPublishedHikeAlwaysHasADistance() {
        #expect(CommunityListing.stub().drawnDistanceMeters != nil)
    }

    /// The callout is the one line a hiker reads before deciding to open the
    /// screen, so what it must not do is lead with a figure that is false.
    /// What it says instead is the half it does have — for a waymarked route,
    /// whether the walk ends back at the car.
    @Test("a lineless pin's callout says the shape rather than zero")
    func theCalloutDropsTheDistance() throws {
        let subtitle = try #require(
            CommunityMapAnnotation(listing: Self.listing(drawn: false)).subtitle
        )

        #expect(!subtitle.contains("0"), "no zero figure: \(subtitle)")
        #expect(subtitle == TrailShape.loop.displayName)
    }

    /// The same pin once its line has arrived, which is what the callout was
    /// written for: the distance leads and the shape follows it.
    @Test("a drawn pin's callout leads with the distance")
    func theCalloutLeadsWithTheDistance() throws {
        let subtitle = try #require(
            CommunityMapAnnotation(listing: Self.listing(drawn: true)).subtitle
        )

        #expect(subtitle.contains(TrailShape.loop.displayName))
        #expect(subtitle.contains("·"), "both halves are there: \(subtitle)")
    }
}
