//
//  TrailTagFixtureTests.swift
//  OpenHikesTests
//
//  The bundled graph behind the hike detail screen's Surface and Difficulty
//  sections, checked as arithmetic before any simulator is asked to draw it.
//
//  Both sections are absent until OpenStreetMap has answered for the route, so
//  a UI test that opens a hike and looks for them is really asking a question
//  about a fixture: does `ThumseeLoopTrails` still cover the imported GPX, and
//  do its tags still divide into shares? Answered here it takes a second and
//  names the cause; answered in the simulator it is a section that did not
//  appear, for any of four reasons.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Bundled trail tag fixture")
struct TrailTagFixtureTests {
    /// The imported hike's own route, read from the same bundled file the
    /// `--ui-test-import-gpx` launch argument imports.
    private func fixtureRoute() throws -> [RouteCoordinate] {
        let url = try #require(
            Bundle.main.url(
                forResource: UITestTrailTagFixture.gpxName,
                withExtension: "gpx"
            ),
            "the app bundle should carry the GPX fixture UI tests import"
        )
        return try GPXImport.load(from: url).route
    }

    private func fixtureGraph() throws -> TrailGraph {
        let provider = try #require(
            BundledTrailGraphProvider(
                fixtureName: UITestTrailTagFixture.trailGraphName
            )
        )
        return try #require(provider.cachedGraph(covering: []))
    }

    @Test("the fixture graph attributes a surface to the whole imported route")
    func surfaceBreakdownCoversTheRoute() async throws {
        let breakdown = try await TrailSurfaceAnalyzer.breakdown(
            route: fixtureRoute(),
            graph: fixtureGraph()
        )

        #expect(!breakdown.isEmpty)
        #expect(
            breakdown.surveyedFraction
                >= UITestTrailTagFixture.minimumSurveyedFraction
        )
        // Three tagged stretches, so the bar has three bands to draw and the
        // legend three rows to speak. One would render as a solid block and
        // prove nothing about either.
        for surface in UITestTrailTagFixture.surfaces {
            #expect(
                breakdown.meters(for: surface) > 0,
                "the fixture should still contain \(surface.rawValue)"
            )
        }
        #expect(breakdown.meters(for: .unmapped) == 0)
    }

    @Test("the fixture graph grades the whole imported route")
    func difficultyBreakdownCoversTheRoute() async throws {
        let breakdown = try await TrailDifficultyAnalyzer.breakdown(
            route: fixtureRoute(),
            graph: fixtureGraph()
        )

        #expect(!breakdown.isEmpty)
        #expect(
            breakdown.surveyedFraction
                >= UITestTrailTagFixture.minimumSurveyedFraction
        )
        for difficulty in UITestTrailTagFixture.difficulties {
            #expect(
                breakdown.meters(for: difficulty) > 0,
                "the fixture should still contain \(difficulty.rawValue)"
            )
        }
        #expect(breakdown.meters(for: .unmapped) == 0)
    }
}

/// The tagged graph behind the hike detail screen's Surface and Difficulty
/// sections, and what the UI test expects to read off them.
///
/// The graph is the imported GPX's own geometry, simplified to within 4 m of
/// it and tagged in three stretches — so coverage is total by construction and
/// the only things that can drift are the tolerance and the tags themselves.
enum UITestTrailTagFixture {
    static let trailGraphName = "ThumseeLoopTrails"
    static let gpxName = "ThumseeLoopFast"
    /// The three tagged stretches, in the order they are walked.
    static let surfaces: [TrailSurface] = [.gravel, .ground, .paved]
    static let difficulties: [TrailDifficulty] = [.hiking, .mountainHiking]
    /// The fixture covers the whole route by construction, so anything much
    /// below this means the simplification or the analyzer's tolerance has
    /// drifted.
    static let minimumSurveyedFraction = 0.95
}
