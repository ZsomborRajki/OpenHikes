//
//  RouteDifficultyShadingTests.swift
//  OpenHikesTests
//
//  What the map is told to colour the selected line by, and when it is told
//  nothing: the switch, the selection moving on, and a route OSM has already
//  said it grades nowhere.
//
//  Measured against the bundled trail-tag fixture — the graph and GPX the
//  Difficulty section's own UI test draws from — so a stretch here and a share
//  of that bar are the same answer about the same ground.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@MainActor
@Suite("Route difficulty shading")
struct RouteDifficultyShadingTests {
    private func fixtureRoute() throws -> [RouteCoordinate] {
        let url = try #require(
            Bundle.main.url(forResource: UITestTrailTagFixture.gpxName, withExtension: "gpx"),
            "the app bundle should carry the GPX fixture UI tests import"
        )
        return try GPXImport.load(from: url).route
    }

    private func fixtureProvider() throws -> BundledTrailGraphProvider {
        try #require(BundledTrailGraphProvider(fixtureName: UITestTrailTagFixture.trailGraphName))
    }

    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "RouteDifficultyShadingTests-\(UUID().uuidString)"))
    }

    private static func length(of coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
            total + RouteGeometry.distanceMeters(from: pair.0, to: pair.1)
        }
    }

    @Test("following a graded hike publishes its graded stretches, and only those")
    func followingMeasuresTheHike() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: try scratchDefaults())

        shading.follow(hike)
        await shading.measurement?.value

        #expect(shading.hikeID == hike.id)
        #expect(!shading.stretches.isEmpty)
        // Outside the macro: `#expect` cannot take a rethrowing key-path call.
        let allGraded = shading.stretches.allSatisfy(\.difficulty.isSurveyed)
        #expect(allGraded)
    }

    /// The legend is shared, so the metres drawn in a grade's colour have to
    /// be the metres the Difficulty bar gives that grade.
    @Test("the stretches drawn in each grade are that grade's share of the Difficulty breakdown")
    func stretchesMatchTheBreakdown() async throws {
        let route = try fixtureRoute()
        let provider = try fixtureProvider()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: route)
        let shading = RouteDifficultyShading(provider: provider, defaults: try scratchDefaults())

        shading.follow(hike)
        await shading.measurement?.value
        let breakdown = try #require(await HikeTrailAnalysis.breakdowns(route: route, provider: provider).difficulty)

        var drawn: [TrailDifficulty: Double] = [:]
        for stretch in shading.stretches {
            drawn[stretch.difficulty, default: 0] += Self.length(of: stretch.coordinates)
        }
        for share in breakdown.shares where share.category.isSurveyed {
            #expect(drawn[share.category, default: 0].isApproximatelyEqual(to: share.meters, absoluteTolerance: 1))
        }
        #expect(Set(drawn.keys) == Set(breakdown.shares.map(\.category).filter(\.isSurveyed)))
    }

    @Test("the switch is on until it is turned off, and stays off for the next launch")
    func theSwitchIsRemembered() throws {
        let defaults = try scratchDefaults()
        let shading = RouteDifficultyShading(provider: nil, defaults: defaults)
        #expect(shading.isEnabled)

        shading.setEnabled(false)

        #expect(defaults.object(forKey: SettingsKey.routeDifficultyColors) as? Bool == false)
        #expect(!RouteDifficultyShading(provider: nil, defaults: defaults).isEnabled)
    }

    @Test("turning the switch off clears the line, and on measures it again")
    func theSwitchClearsAndRestores() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: try scratchDefaults())
        shading.follow(hike)
        await shading.measurement?.value
        let revision = shading.revision

        shading.setEnabled(false)

        #expect(shading.stretches.isEmpty)
        #expect(shading.hikeID == nil)
        #expect(shading.revision != revision)

        shading.setEnabled(true)
        await shading.measurement?.value

        #expect(shading.hikeID == hike.id)
        #expect(!shading.stretches.isEmpty)
    }

    @Test("with the switch off, following a hike measures nothing")
    func offMeansNoFetch() throws {
        let defaults = try scratchDefaults()
        defaults.set(false, forKey: SettingsKey.routeDifficultyColors)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: defaults)

        shading.follow(hike)

        #expect(shading.measurement == nil)
        #expect(shading.stretches.isEmpty)
    }

    @Test("deselecting clears the line at once")
    func followingNilClears() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: try scratchDefaults())
        shading.follow(hike)
        await shading.measurement?.value

        shading.follow(nil)

        #expect(shading.hikeID == nil)
        #expect(shading.stretches.isEmpty)
        #expect(shading.measurement == nil)
    }

    /// The stretches are published against the hike they were measured along,
    /// and a different hike clears them before its own answer arrives — so
    /// the map can never draw one hike's grades along another's line.
    @Test("selecting another hike drops the last one's stretches before measuring")
    func anotherHikeClearsFirst() async throws {
        let context = try Fixture.modelContext()
        let route = try fixtureRoute()
        let first = Fixture.hike(in: context, route: route)
        let second = Fixture.hike(in: context, title: "Second", route: route)
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: try scratchDefaults())
        shading.follow(first)
        await shading.measurement?.value

        shading.follow(second)

        #expect(shading.hikeID == nil)
        #expect(shading.stretches.isEmpty)
        await shading.measurement?.value
        #expect(shading.hikeID == second.id)
    }

    @Test("a hike whose stored breakdown grades nothing is not measured again")
    func anUngradedBreakdownAsksNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        hike.difficultyBreakdown = TrailDifficultyBreakdown(metersByCategory: [.unknown: 800, .unmapped: 200])
        let shading = RouteDifficultyShading(provider: try fixtureProvider(), defaults: try scratchDefaults())

        shading.follow(hike)

        #expect(shading.measurement == nil)
    }
}
