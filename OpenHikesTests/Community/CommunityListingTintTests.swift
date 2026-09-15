//
//  CommunityListingTintTests.swift
//  OpenHikesTests
//
//  The colour a shared hike is drawn in.
//
//  Four places read ``CommunityListing/tint`` — the row's circle, the map pin,
//  the line under it and the graph on the preview — and none of them can be
//  read back from a rendered view. What can be asserted is the property they
//  all share a source in, and the one thing that would break all four at once:
//  a colour that is not a function of the listing's identity alone.
//
//  That is not a theoretical failure. A listing is a value re-fetched by every
//  search, rebuilt from scratch each time an answer lands, and carrying a
//  `publishedAt` that is *the moment it was fetched* for a curated route. A
//  colour derived from anything but the id would change under a hiker between
//  one *Search this area* and the next.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Community listing tint")
struct CommunityListingTintTests {
    private static let centre = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
    /// Out of the twenty-four listings ``aPageOfResultsIsNotOneColour`` builds.
    private static let distinctFloor = 22

    /// A curated trail, small enough to be a day hike and otherwise
    /// uninteresting: nothing here asserts anything about its geometry.
    private static func trail(_ relationID: Int64, named name: String = "Soleleitensteig") -> CuratedTrail {
        let halfSpan = 0.004
        let box = CuratedTrailQuery.BoundingBox(
            south: centre.latitude - halfSpan,
            west: centre.longitude - halfSpan,
            north: centre.latitude + halfSpan,
            east: centre.longitude + halfSpan
        )
        return CuratedTrail(
            relationID: relationID,
            name: name,
            tags: ["name": name, "route": "hiking"],
            box: box,
            route: [
                RouteCoordinate(latitude: box.south, longitude: box.west),
                RouteCoordinate(latitude: box.north, longitude: box.east),
            ]
        )
    }

    /// The re-fetch. Two listings for one relation, built minutes apart, as
    /// two searches over the same valley would build them.
    ///
    /// `editedAt` deliberately differs, because it always does: it is `.now`
    /// at the moment the row was fetched — see
    /// ``CommunityListing/init(curated:editedAt:)``. A colour that took it
    /// into account would pass every other test in this file.
    @Test("a curated route keeps its colour when the search is run again")
    func curatedColourSurvivesARefetch() {
        let trail = Self.trail(411)
        let first = CommunityListing(curated: trail, editedAt: Date(timeIntervalSince1970: 1_000_000))
        let second = CommunityListing(curated: trail, editedAt: Date(timeIntervalSince1970: 2_000_000))

        #expect(first.tint.hexRGBA == second.tint.hexRGBA)
    }

    /// The same for a published hike, whose listing is rebuilt from its
    /// CloudKit record on every page of results.
    @Test("a published hike keeps its colour across pages of results")
    func publishedColourIsStable() {
        let first = CommunityListing.stub(id: "record-abc", title: "Pilis Ridge")
        // The same hike, re-read with a field that has since changed: a
        // reviewer corrected the title and two more photographs landed.
        let second = CommunityListing.stub(id: "record-abc", title: "Pilis Ridge (north)", photoCount: 4)

        #expect(first.tint.hexRGBA == second.tint.hexRGBA)
    }

    /// The point of the whole change: a page of results is not one colour.
    ///
    /// Both sources together, because a merged list is what a hiker actually
    /// sees — see ``MergedCommunityTransport`` — and two trails from different
    /// sources sitting in the same valley must not come out alike either.
    ///
    /// A floor rather than "all of them distinct", for the reason
    /// ``RouteTintTests`` spells out: two hues a fraction of a degree apart
    /// round to the same three bytes, and that is a distinction nobody can
    /// see. What is being ruled out is a page drawn in one colour.
    @Test("a page of mixed results is a page of different colours")
    func aPageOfResultsIsNotOneColour() {
        let curated = (1_000_000...1_000_011).map { relationID in
            CommunityListing(curated: Self.trail(relationID), editedAt: .now)
        }
        let published = (1...12).map { CommunityListing.stub(id: "record-\($0)") }
        let colours = Set((curated + published).map(\.tint.hexRGBA))

        #expect(colours.count >= Self.distinctFloor, "a mixed page of 24 drew \(colours.count) colours")
    }

    /// What the import stores has to be what the hiker was looking at. The two
    /// spellings exist so that ``CommunityImport`` need not import SwiftUI,
    /// and nothing else keeps them in step.
    @Test("the stored spelling names the colour that was on screen")
    func hexMatchesTheColour() {
        for listing in [CommunityListing.stub(), CommunityListing(curated: Self.trail(9), editedAt: .now)] {
            let parsed = Color(hex: listing.tintHex)
            #expect(parsed?.hexRGBA == listing.tint.hexRGBA)
        }
    }

    /// A curated id and a record name cannot collide by construction — the
    /// prefix is there to stop exactly that, see
    /// ``CommunityIdentity/curatedPrefix`` — so neither can their colours.
    @Test("a curated route and a published hike of the same number differ")
    func sourcesDoNotCollide() {
        let curated = CommunityListing(curated: Self.trail(1234), editedAt: .now)
        let published = CommunityListing.stub(id: "1234")

        #expect(curated.tint.hexRGBA != published.tint.hexRGBA)
    }
}
