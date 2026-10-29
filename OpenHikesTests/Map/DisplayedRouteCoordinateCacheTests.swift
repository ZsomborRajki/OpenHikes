//
//  DisplayedRouteCoordinateCacheTests.swift
//  OpenHikesTests
//
//  The selected route's projection is made off the main actor, from the
//  selection's change handler, and the root body only reads what has landed
//  (#1232). Made in the body, a long trail's first pass mapped and walked
//  every point on the main actor.
//
//  It is kept per line, not per hike. *Edit Route* keeps the hike's id and
//  replaces its line, and mirroring delivers that edit while the hike can be
//  selected (#1228), so the cache has to notice a write to `route` — and only
//  that: an appearance write or a body pass that changes nothing must still
//  be answered from the cache.
//
//  Where the projection runs is asserted through the cache's build seam, as
//  `PinnedTrailReadTests` asserts its read through the fetch: the build
//  records the thread it ran on.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Synchronization
import Testing

@Suite("Displayed route coordinate cache")
struct DisplayedRouteCoordinateCacheTests {
    /// Which threads the projection ran on, one entry per call.
    nonisolated final class BuildLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func build(_ route: [RouteCoordinate], revision: Int) -> DisplayedRouteCoordinateCache.DrawnRoute {
            threads.withLock { $0.append(Thread.isMainThread) }
            return DisplayedRouteCoordinateCache.DrawnRoute(route: route, revision: revision)
        }
    }

    private static let originalRoute = [
        RouteCoordinate(latitude: 47.63, longitude: 12.86),
        RouteCoordinate(latitude: 47.64, longitude: 12.87),
    ]

    private static let replacementRoute = [
        RouteCoordinate(latitude: 48, longitude: 13),
        RouteCoordinate(latitude: 48.01, longitude: 13.01),
    ]

    /// Six points along one line, paused at the fourth when `paused` is set:
    /// the same geometry either way, so only the boundary tells them apart.
    private static func sixPoints(paused: Bool) -> [RouteCoordinate] {
        (0..<6).map { index in
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.86 + Double(index) * 0.001,
                boundary: paused && index == 3 ? .paused : nil
            )
        }
    }

    /// The caller is the main actor itself, so a projection that stays on its
    /// caller's executor fails.
    @Test("a selected route is projected off the main thread")
    func theProjectionRunsOffTheMainThread() async {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)

        cache.prepare(for: hike)
        await cache.preparation?.value

        #expect(log.ranOnMainThread == [false])
        let drawn = DisplayedRoute.forSelection(hike, cache: cache)
        #expect(drawn?.id == hike.id)
        #expect(drawn?.coordinates.map(\.latitude) == Fixture.coordinates(Fixture.ridgeRoute).map(\.latitude))
    }

    /// The body reads only what has landed, so it never pays for a projection
    /// itself, and it hears the landing so the map is handed the line.
    @Test("the root view draws nothing until the projection lands, then hears it once")
    func theBodyWaitsForTheProjection() async {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)
        let rootView = ObservationCounter { _ = DisplayedRoute.forSelection(hike, cache: cache) }

        cache.prepare(for: hike)
        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil, "the body must not project it in place")
        await cache.preparation?.value
        await rootView.settle()

        #expect(rootView.count == 1)
        #expect(DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count == Fixture.ridgeRoute.count)

        cache.prepare(for: hike)
        #expect(log.ranOnMainThread.count == 1, "the same selection again projects nothing")
    }

    /// A deselection made while the projection was in flight: the answer
    /// that lands afterwards belongs to a selection that is gone.
    @Test("a projection for a selection that moved on is dropped")
    func aStaleProjectionIsDropped() async {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        let stale = cache.preparation
        cache.prepare(for: nil)
        await stale?.value

        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil)
    }

    /// The appearance writes are waited out by a write to the line, which
    /// must be projected: had they started a projection too, there would be
    /// three.
    @Test("a line nobody wrote is answered from the cache")
    func unchangedLineIsKept() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)
        cache.prepare(for: hike)
        await cache.preparation?.value
        let first = try #require(cache.drawnRoute(for: hike))

        hike.tintHex = "#FF0000FF"
        hike.routeWidth = 9
        await settleDelegateHop()
        #expect(cache.drawnRoute(for: hike)?.revision == first.revision, "an appearance write is not a new line")

        hike.replaceRoute(with: Self.replacementRoute)
        await settleDelegateHop(until: "the new line lands") {
            cache.drawnRoute(for: hike)?.coordinates.first?.latitude == 48
        }
        #expect(log.ranOnMainThread.count == 2)
    }

    /// The issue's own probe: a stored hike, its line replaced under the same
    /// id, with no change of selection.
    @Test("a new line for the selected hike is projected again")
    func replacedLineIsProjectedAgain() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)
        cache.prepare(for: hike)
        await cache.preparation?.value
        let before = try #require(cache.drawnRoute(for: hike))
        #expect(before.coordinates.first?.latitude == 47.63)

        hike.replaceRoute(with: Self.replacementRoute)
        await settleDelegateHop(until: "the new line lands") {
            cache.drawnRoute(for: hike)?.coordinates.first?.latitude == 48
        }

        let after = try #require(cache.drawnRoute(for: hike))
        #expect(after.revision != before.revision)
        #expect(log.ranOnMainThread == [false, false], "…off the main thread, once, and then kept again")
    }

    /// A line can change without moving: a pause added at a point already on
    /// it changes where the line is cut and which leg is drawn dotted.
    @Test("a pause added to the selected hike's line reaches the drawn route")
    func pauseBoundaryEditIsProjectedAgain() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.sixPoints(paused: false))
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value
        let before = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        #expect(before.runs.pausedLegs.isEmpty)
        #expect(before.pausedSegments.isEmpty)

        hike.replaceRoute(with: Self.sixPoints(paused: true))
        await settleDelegateHop(until: "the new line lands") {
            DisplayedRoute.forSelection(hike, cache: cache) != before
        }
        let after = try #require(DisplayedRoute.forSelection(hike, cache: cache))

        #expect(after.runs.pausedLegs == [2])
        #expect(after.pausedSegments.count == 1)
    }

    /// What `OpenHikesView`'s body reads must change with the line, or a
    /// write to it would re-run nothing and the map would keep the old one.
    /// Projected once first, so the pass observed is one the cache answers:
    /// the body's ordinary pass, which reads no route value of its own.
    @Test("a new line reaches whoever drew the old one, once")
    func routeWriteInvalidatesTheReader() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value
        let reader = ObservationCounter { _ = DisplayedRoute.forSelection(hike, cache: cache) }
        await reader.settle()

        hike.replaceRoute(with: Self.sixPoints(paused: false))
        await settleDelegateHop(until: "the new line reaches the reader") {
            reader.count >= 1 && DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count == 6
        }
        await reader.settle()

        #expect(reader.count == 1, "the landing, and not the write before it")
    }

    /// The line was read for a projection that has not landed yet when it is
    /// replaced. Whichever comes first drops that projection: the flag the
    /// write raised, or the generation the hop projecting the new line moves
    /// on.
    @Test("a line replaced while its projection was in flight is never drawn")
    func aProjectionOfAReplacedLineIsDropped() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        let inFlight = cache.preparation
        hike.replaceRoute(with: Self.replacementRoute)
        await inFlight?.value

        #expect(cache.drawnRoute(for: hike)?.coordinates.first?.latitude != 47.63, "the line before the write")
        await settleDelegateHop(until: "the new line lands") {
            cache.drawnRoute(for: hike)?.coordinates.first?.latitude == 48
        }
    }

    /// A projection's watch outlives the selection it was armed for, because
    /// an observation can only be ignored. Ignored it must be: a write to a
    /// hike no longer drawn is not a new line for the one that is. Waited out
    /// by a write to the drawn hike, whose hop runs after the other's: by the
    /// time its line lands, every projection either write started has been
    /// numbered, and there must be only the one.
    @Test("a write to a hike no longer drawn projects nothing")
    func aWriteToAnUnselectedHikeIsIgnored() async throws {
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context, title: "First", route: Self.originalRoute)
        let second = Fixture.hike(in: context, title: "Second", route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: first)
        await cache.preparation?.value
        cache.prepare(for: second)
        await cache.preparation?.value
        let drawn = try #require(cache.drawnRoute(for: second))

        first.replaceRoute(with: Self.replacementRoute)
        second.replaceRoute(with: Self.sixPoints(paused: false))
        await settleDelegateHop(until: "the drawn hike's new line lands") {
            cache.drawnRoute(for: second)?.coordinates.count == 6
        }

        #expect(cache.drawnRoute(for: second)?.revision == drawn.revision + 1)
    }

    @Test("clearing the selection releases the cached route")
    func clearDropsCachedCoordinates() async throws {
        let hike = Hike(title: "Cached", distanceMeters: 1000, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value
        let before = try #require(cache.drawnRoute(for: hike))
        #expect(before.coordinates.count == 2)

        cache.prepare(for: nil)
        #expect(cache.drawnRoute(for: hike) == nil)

        cache.prepare(for: hike)
        await cache.preparation?.value
        let refreshed = try #require(cache.drawnRoute(for: hike))
        #expect(refreshed.coordinates.count == 2)
        #expect(refreshed.revision != before.revision, "projected again, not handed back")
    }

    @Test("the recording screen never draws the previously selected finished route")
    func recordingPresentationSuppressesFinishedRoute() async {
        let hike = Hike(
            title: "Imported Track",
            distanceMeters: 1000,
            route: Fixture.ridgeRoute
        )
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value

        #expect(
            DisplayedRoute.forSelection(
                hike,
                cache: cache,
                recordingPresented: true
            ) == nil
        )
        #expect(
            DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count
                == Fixture.ridgeRoute.count
        )
    }

    @Test("an active recording draft is not treated as a finished route")
    func recordingDraftIsSuppressedUntilFinalized() async {
        let hike = Hike(
            title: "Morning Hike",
            distanceMeters: 0,
            route: Fixture.ridgeRoute,
            isRecording: true
        )
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        #expect(cache.preparation == nil, "a draft's line is the recorder's to draw")
        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil)

        hike.isRecording = false
        cache.prepare(for: hike)
        await cache.preparation?.value
        #expect(
            DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count
                == Fixture.ridgeRoute.count
        )
    }
}
