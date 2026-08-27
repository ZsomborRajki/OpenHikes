//
//  RouteStyleTrackingTests.swift
//  OpenHikesTests
//
//  `RouteStyle.follow(_:)` is the only thing that decides which hike's
//  appearance the map line answers to. What it holds while following, and what
//  it lets go of when told to follow nothing, is the whole of its state.
//

@testable import OpenHikes
import Testing

@MainActor
@Suite("Route style tracking")
struct RouteStyleTrackingTests {
    @Test("following a hike takes its appearance and holds it")
    func followingAdoptsTheHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.routeWidth = 9
        let style = RouteStyle()

        style.follow(hike)

        #expect(style.trackedHike === hike)
        #expect(style.width == 9)
    }

    /// The defaults coming back is what a reader would notice; the reference
    /// going away is what this is really asserting, because nothing else
    /// distinguishes a cleared field from one still pointing at the hike the
    /// user just deselected.
    @Test("following nil restores the defaults and lets go of the hike")
    func followingNilClearsTheTrackedHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.routeWidth = 9
        let style = RouteStyle()
        style.follow(hike)

        style.follow(nil)

        #expect(style.trackedHike == nil)
        #expect(style.width == RouteStyle.defaultWidth)
    }

    /// A write arriving after the deselection must not reinstate the old
    /// hike's appearance — the registration it was made under is dead, and
    /// with the reference gone there is nothing left for it to read either.
    @Test("a deselected hike's later writes no longer reach the style")
    func writesAfterDeselectionAreIgnored() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let style = RouteStyle()
        style.follow(hike)
        style.follow(nil)

        let observed = ObservationCounter { _ = style.width }
        await observed.settle()
        hike.routeWidth = 12
        await observed.settle()

        #expect(observed.count == 0)
        #expect(style.width == RouteStyle.defaultWidth)
        #expect(style.trackedHike == nil)
    }

    @Test("following a second hike replaces the first")
    func followingAnotherHikeReplacesTheTrackedOne() throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(in: context)
        let style = RouteStyle()

        style.follow(first)
        style.follow(second)

        #expect(style.trackedHike === second)
    }
}
