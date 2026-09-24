//
//  SeededTrailPointSourceTests.swift
//  OpenHikesTests
//
//  The stand-in place search the place audits are built on, checked here so a
//  seed that drifted off the fixture's line reports as that — rather than as
//  an audit of an empty sheet, which reads as a broken screen.
//
//  Run through the shipping searches rather than read back directly, because
//  what the seed has to survive is exactly them: the corridor search keeps
//  only what the line passes, and the recording sheet only what is within
//  reach of the trailhead the recording scenarios stand on.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Seeded trail point source")
struct SeededTrailPointSourceTests {
    /// The fixture `PlaceUITests` and the place audits import.
    private static let fixtureName = "ThumseeLoopPlaces"

    private func fixture() throws -> GPXImport.Track {
        let url = try #require(
            Bundle.main.url(forResource: Self.fixtureName, withExtension: "gpx"),
            "the app bundle should carry the GPX fixture the place audits import"
        )
        return try GPXImport.load(from: url)
    }

    @Test("only a named scenario produces a source")
    func scenariosAreOptIn() {
        #expect(SeededTrailPointSource.Scenario(argument: nil) == nil)
        #expect(SeededTrailPointSource.Scenario(argument: "") == nil)
        #expect(SeededTrailPointSource.Scenario(argument: "Seeded") == nil)
        for scenario in SeededTrailPointSource.Scenario.allCases {
            #expect(SeededTrailPointSource.Scenario(argument: scenario.rawValue) == scenario)
        }
    }

    @Test("every seeded place is on the fixture's line and none is one it already holds")
    func seededPlacesSurviveTheCorridorSearch() async throws {
        let track = try fixture()

        let outcome = try await TrailPlaceCorridorSearch.search(
            along: track.route,
            excluding: track.places,
            from: SeededTrailPointSource(scenario: .seeded),
            showing: Set(TrailPlaceSymbol.allCases)
        )

        #expect(outcome.outage == nil)
        #expect(
            Set(outcome.rows.map(\.place.osm?.elementID))
                == Set(SeededTrailPointSource.places.map(\.osm?.elementID))
        )
    }

    @Test("a recording at the trailhead is offered more than one mapped place")
    func trailheadHasSuggestions() async throws {
        let trailhead = try #require(try fixture().route.first)
        let here = CLLocationCoordinate2D(latitude: trailhead.latitude, longitude: trailhead.longitude)
        let source: any TrailPointSourcing = SeededTrailPointSource(scenario: .seeded)

        let found = try await source.places(
            near: NearbyPlaceSuggestions.area(around: here),
            showing: Set(TrailPlaceSymbol.allCases)
        )
        let offered = NearbyPlaceSuggestions.suggestions(from: found, around: here, excluding: [])

        #expect(offered.count == 2)
    }

    @Test("a refused search is an outage with nothing found")
    func refusedIsAnOutage() async throws {
        let track = try fixture()

        let outcome = try await TrailPlaceCorridorSearch.search(
            along: track.route,
            excluding: track.places,
            from: SeededTrailPointSource(scenario: .refused),
            showing: Set(TrailPlaceSymbol.allCases)
        )

        #expect(outcome.rows.isEmpty)
        #expect(outcome.outage == .unavailable)
    }
}
