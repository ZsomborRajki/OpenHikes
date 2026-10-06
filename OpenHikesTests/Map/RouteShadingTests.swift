//
//  RouteShadingTests.swift
//  OpenHikesTests
//
//  What the map is told to colour the selected line by, and when it is told
//  nothing: the *Color By* control, the selection moving on, and a route OSM
//  has already said it grades nowhere.
//
//  Measured against the bundled trail-tag fixture — the graph and GPX the
//  Difficulty section's own UI test draws from — so a stretch here and a share
//  of that bar are the same answer about the same ground. `RouteSteepnessTests`
//  covers how steepness is measured; this covers that it reaches the map.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@MainActor
@Suite("Route shading")
struct RouteShadingTests {
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
        try #require(UserDefaults(suiteName: "RouteShadingTests-\(UUID().uuidString)"))
    }

    /// Scratch defaults with the control at *Difficulty*, which is what most
    /// of these are about and is not the default.
    private func difficultyDefaults() throws -> UserDefaults {
        let defaults = try scratchDefaults()
        defaults.set(RouteColoring.difficulty.rawValue, forKey: SettingsKey.routeColoring)
        return defaults
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
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())

        shading.follow(hike)
        await shading.measurement?.value

        #expect(shading.hikeID == hike.id)
        #expect(!shading.stretches.isEmpty)
    }

    /// The legend is shared, so the metres drawn in a grade's colour have to
    /// be the metres the Difficulty bar gives that grade.
    @Test("the stretches drawn in each grade are that grade's share of the Difficulty breakdown")
    func stretchesMatchTheBreakdown() async throws {
        let route = try fixtureRoute()
        let provider = try fixtureProvider()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: route)
        let shading = RouteShading(provider: provider, defaults: try difficultyDefaults())

        shading.follow(hike)
        await shading.measurement?.value
        let breakdown = try #require(await HikeTrailAnalysis.breakdowns(route: route, provider: provider).difficulty)

        var drawn: [RouteShade: Double] = [:]
        for stretch in shading.stretches {
            drawn[stretch.shade, default: 0] += Self.length(of: stretch.coordinates)
        }
        for share in breakdown.shares {
            guard let shade = share.category.shade else { continue }
            #expect(drawn[shade, default: 0].isApproximatelyEqual(to: share.meters, absoluteTolerance: 1))
        }
        #expect(Set(drawn.keys) == Set(breakdown.shares.compactMap(\.category.shade)))
    }

    @Test("colouring is by elevation until it is changed, and the change outlives the launch")
    func theColoringIsRemembered() throws {
        let defaults = try scratchDefaults()
        let shading = RouteShading(provider: nil, defaults: defaults)
        #expect(shading.coloring == .elevation)

        shading.setColoring(.difficulty)

        #expect(defaults.string(forKey: SettingsKey.routeColoring) == RouteColoring.difficulty.rawValue)
        #expect(RouteShading(provider: nil, defaults: defaults).coloring == .difficulty)
    }

    /// The control replaced an on/off switch; a hiker who had turned that
    /// off should not find the colours back on after updating.
    @Test("the old switch, turned off, reads as None until the control is moved")
    func theOldSwitchCarriesOver() throws {
        let off = try scratchDefaults()
        off.set(false, forKey: SettingsKey.legacyRouteDifficultyColors)
        #expect(RouteShading(provider: nil, defaults: off).coloring == .off)

        let on = try scratchDefaults()
        on.set(true, forKey: SettingsKey.legacyRouteDifficultyColors)
        #expect(RouteShading(provider: nil, defaults: on).coloring == SettingsDefault.routeColoring)

        off.set(RouteColoring.difficulty.rawValue, forKey: SettingsKey.routeColoring)
        #expect(RouteShading(provider: nil, defaults: off).coloring == .difficulty)
    }

    @Test("None clears the line, and Difficulty measures it again")
    func noneClearsAndDifficultyRestores() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())
        shading.follow(hike)
        await shading.measurement?.value
        let revision = shading.revision

        shading.setColoring(.off)

        #expect(shading.stretches.isEmpty)
        #expect(shading.hikeID == nil)
        #expect(shading.revision != revision)

        shading.setColoring(.difficulty)
        await shading.measurement?.value

        #expect(shading.hikeID == hike.id)
        #expect(!shading.stretches.isEmpty)
    }

    @Test("at None, following a hike measures nothing")
    func noneMeansNoFetch() throws {
        let defaults = try scratchDefaults()
        defaults.set(RouteColoring.off.rawValue, forKey: SettingsKey.routeColoring)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteShading(provider: try fixtureProvider(), defaults: defaults)

        shading.follow(hike)

        #expect(shading.measurement == nil)
        #expect(shading.stretches.isEmpty)
    }

    @Test("deselecting clears the line at once")
    func followingNilClears() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())
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
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())
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
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())

        shading.follow(hike)

        #expect(shading.measurement == nil)
    }

    /// Following the same hike keeps its stretches up while it is measured
    /// again; one whose stored breakdown now grades nothing is not measured,
    /// so the stretches must go then rather than stay over the line.
    @Test("the same hike followed again with no grades left clears its stretches")
    func refollowingAnUngradedHikeClears() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())
        shading.follow(hike)
        await shading.measurement?.value
        #expect(!shading.stretches.isEmpty)

        hike.difficultyBreakdown = TrailDifficultyBreakdown(metersByCategory: [.unknown: 800, .unmapped: 200])
        shading.follow(hike)

        #expect(shading.measurement == nil)
        #expect(shading.hikeID == nil)
        #expect(shading.stretches.isEmpty)
    }

    /// Steepness reads the heights the route already carries, so it needs
    /// no trail graph — and its answer is ``RouteSteepness``'s, step for step.
    @Test("by elevation, the stretches are the route's steepness, with no trail graph")
    func elevationMeasuresSteepness() async throws {
        let route = try fixtureRoute()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: route)
        let defaults = try scratchDefaults()
        defaults.set(RouteColoring.elevation.rawValue, forKey: SettingsKey.routeColoring)
        let shading = RouteShading(provider: nil, defaults: defaults)

        shading.follow(hike)
        await shading.measurement?.value

        let expected = RouteSteepness.runs(route: route)
        #expect(!expected.isEmpty, "the fixture GPX should carry heights")
        #expect(shading.hikeID == hike.id)
        #expect(shading.stretches.map(\.shade) == expected.map(\.shade))
        #expect(shading.stretches.map(\.coordinates.count) == expected.map(\.coordinates.count))
    }

    /// The old mode's colours mean something else under the new one, so they
    /// go at once rather than staying up until the new answer lands.
    @Test("moving the control clears the line before measuring it the new way")
    func changingModeClearsFirst() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: try fixtureRoute())
        let shading = RouteShading(provider: try fixtureProvider(), defaults: try difficultyDefaults())
        shading.follow(hike)
        await shading.measurement?.value
        #expect(!shading.stretches.isEmpty)

        shading.setColoring(.elevation)

        #expect(shading.hikeID == nil)
        #expect(shading.stretches.isEmpty)
        await shading.measurement?.value
        #expect(shading.hikeID == hike.id)
        #expect(!shading.stretches.isEmpty)
    }

    @Test("by elevation, a route with no heights colours nothing")
    func noHeightsNoStretches() async throws {
        let context = try Fixture.modelContext()
        let flat = try fixtureRoute().map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        let hike = Fixture.hike(in: context, route: flat)
        let defaults = try scratchDefaults()
        defaults.set(RouteColoring.elevation.rawValue, forKey: SettingsKey.routeColoring)
        let shading = RouteShading(provider: nil, defaults: defaults)

        shading.follow(hike)
        await shading.measurement?.value

        #expect(shading.hikeID == hike.id)
        #expect(shading.stretches.isEmpty)
    }
}
