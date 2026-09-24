//
//  HikeTrailAnalysisTests.swift
//  OpenHikesTests
//
//  One pass over a trail graph, and both breakdowns that come out of it.
//
//  `TrailTagFixtureTests` asks `TrailBreakdownAnalyzer` about a graph handed
//  to it directly, which is the arithmetic. This asks ``HikeTrailAnalysis``,
//  which is what both screens actually call: it resolves the graph through a
//  provider first, and it is where the decision to trust a cache — or to
//  refuse a partial one — lives.
//
//  That path matters more than it did. The hike detail screen runs it once and
//  writes the answer onto the `Hike`, so a wrong `nil` there is a section that
//  is missing until the next open. The community preview has nowhere to store
//  one, so it runs this on every open of a stranger's hike, and a `nil` is two
//  sections that never appear at all.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike trail analysis")
struct HikeTrailAnalysisTests {
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

    private func fixtureProvider() throws -> BundledTrailGraphProvider {
        try #require(
            BundledTrailGraphProvider(
                fixtureName: UITestTrailTagFixture.trailGraphName
            )
        )
    }

    /// The whole of what either screen asks for, in one call: a route, a
    /// provider, and both halves back.
    @Test("a matched route comes back with both breakdowns")
    func bothBreakdownsAreMeasuredFromOneGraph() async throws {
        let breakdowns = await HikeTrailAnalysis.breakdowns(
            route: try fixtureRoute(),
            provider: try fixtureProvider()
        )

        #expect(!breakdowns.isEmpty)
        let surface = try #require(breakdowns.surface)
        let difficulty = try #require(breakdowns.difficulty)
        #expect(
            surface.surveyedFraction
                >= UITestTrailTagFixture.minimumSurveyedFraction
        )
        #expect(
            difficulty.surveyedFraction
                >= UITestTrailTagFixture.minimumSurveyedFraction
        )
    }

    /// A route of one point is not a route, and walking it would divide by a
    /// length of zero. Both screens hand this straight to the provider, so the
    /// refusal has to be here rather than at either call site.
    @Test("a route too short to walk asks the provider nothing")
    func aDegenerateRouteIsRefusedBeforeTheGraph() async throws {
        let point = try #require(fixtureRoute().first)
        let breakdowns = await HikeTrailAnalysis.breakdowns(
            route: [point],
            provider: try fixtureProvider()
        )

        #expect(breakdowns.isEmpty)
    }

    /// A route that runs nowhere near anything the graph knows about, against
    /// a provider that says its coverage is complete. That combination is the
    /// one case where "not mapped" is a measurement rather than a gap, and
    /// both sections draw it as such: a full bar of ``TrailSurface/unmapped``
    /// with a footnote saying how little of the route was described.
    ///
    /// Worth pinning because the alternative is indistinguishable on screen
    /// from a working analysis, and because the guard in
    /// ``HikeTrailAnalysis`` that produces it — refusing a cache that does not
    /// cover the whole route — exists precisely so this answer is never given
    /// about regions nobody has downloaded. A provider claiming completeness
    /// is what makes it honest here; ``OverpassTrailGraphProvider`` answers
    /// per region, which is why the same route through an undownloaded valley
    /// gets nothing instead.
    @Test("a route the graph does not cover is reported as unmapped")
    func anUncoveredRouteIsMeasuredAsUnmapped() async throws {
        let breakdowns = await HikeTrailAnalysis.breakdowns(
            route: Fixture.ridgeRoute,
            provider: try fixtureProvider()
        )

        let surface = try #require(breakdowns.surface)
        let difficulty = try #require(breakdowns.difficulty)
        #expect(surface.surveyedFraction == 0)
        #expect(difficulty.surveyedFraction == 0)
        #expect(surface.meters(for: .unmapped) == surface.totalMeters)
        #expect(difficulty.meters(for: .unmapped) == difficulty.totalMeters)
    }
}
