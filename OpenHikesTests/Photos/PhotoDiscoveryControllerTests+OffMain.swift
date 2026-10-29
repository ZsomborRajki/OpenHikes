//
//  PhotoDiscoveryControllerTests+OffMain.swift
//  OpenHikesTests
//
//  Where a search's route-sized work runs, and which search gets to write.
//
//  The controller is main-actor isolated, and it used to build the plan's
//  indexes and match the library's whole answer synchronously in its own
//  `search(in:)` — most of a second on a long, walked trail, with the sheet
//  frozen in front of it (#1119) — and, once those had moved, still read the
//  hike there first, decoding and hashing the route (#1215). Asserted through
//  the work seam rather than a stopwatch, as `HikeIntentLibrarySweepTests`
//  asserts its read: each step records the thread it ran on, and the caller
//  is the main actor itself, so a step that stays on its caller's executor
//  fails.
//
//  Moving the match behind an `await` opens a window the synchronous one
//  never had, so *a search overtaken by a newer one writes nothing* pins who
//  may close it: only the newest search writes.
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension for the reason
//  the other halves are: one test type per file, and these share every
//  fixture with the tests next door.
//

import Dispatch
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// Which threads each step of a search ran on, one entry per call.
    nonisolated final class WorkLog: Sendable {
        private let threads = Mutex<(fetches: [Bool], plans: [Bool], matches: [Bool])>(([], [], []))

        /// One entry per hike fetched from the store, which only a saved hike
        /// is — see ``HikePhotoSearchPlan/SourceRead``.
        var fetchesOnMainThread: [Bool] { threads.withLock(\.fetches) }
        var plansOnMainThread: [Bool] { threads.withLock(\.plans) }
        var matchesOnMainThread: [Bool] { threads.withLock(\.matches) }

        /// The real work, recording where each step ran before doing it.
        var work: PhotoDiscoveryWork {
            PhotoDiscoveryWork(
                fetchHike: { context, id in
                    self.threads.withLock { $0.fetches.append(Thread.isMainThread) }
                    return try PhotoDiscoveryWork.standard.fetchHike(context, id)
                },
                buildPlan: { source in
                    self.threads.withLock { $0.plans.append(Thread.isMainThread) }
                    return PhotoDiscoveryWork.standard.buildPlan(source)
                },
                matchAssets: { plan, assets, alreadyImported in
                    self.threads.withLock { $0.matches.append(Thread.isMainThread) }
                    return PhotoDiscoveryWork.standard.matchAssets(plan, assets, alreadyImported)
                }
            )
        }
    }

    @Test("a search indexes the route and matches the batch off the main thread")
    func searchWorkLeavesTheMainThread() async throws {
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift
        // makes unavailable from an `async` context.
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let log = WorkLog()
        let controller = PhotoDiscoveryController(reader: library, work: log.work)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(log.plansOnMainThread == [false])
        #expect(log.matchesOnMainThread == [false])
        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["a"])
    }

    /// The read before the plan was route-sized too: the route decoded on
    /// first access and, with a walk along it, hashed again to tell the walk
    /// is along its line (#1215). A saved hike is read in a context of the
    /// search's own instead, and finds what the same hike read on the main
    /// actor finds: one photograph placed by the route's clock and one by
    /// the walk, a day later.
    @Test("a saved hike's route is read off the main thread, to the same matches")
    func savedHikeIsReadOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("route", atStep: 2),
                PhotoDiscoveryFixture.asset("walk", atStep: Self.walkDay + 4.5),
            ]
        )
        let log = WorkLog()
        let savedContext = try Fixture.modelContext()
        let saved = Self.walkedHike(in: savedContext)
        try savedContext.save()
        let unsavedContext = try Fixture.modelContext()
        let unsaved = Self.walkedHike(in: unsavedContext)

        let controller = PhotoDiscoveryController(reader: library, work: log.work)
        await controller.search(in: unsaved)
        let readOnTheMainActor = controller.matches
        await controller.search(in: saved)

        #expect(log.fetchesOnMainThread == [false], "only the saved hike is fetched, and off the main thread")
        #expect(log.plansOnMainThread == [false, false])
        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["route", "walk"])
        #expect(controller.matches.map(\.evidence) == [.time, .walk])
        #expect(controller.matches == readOnTheMainActor)
    }

    /// The hike is named on the main actor and read off it, so its row can go
    /// in between: deleted through another context, as an import of a
    /// deletion made on another device is, which this hike's own context has
    /// not merged. Then there is nothing to search and nothing true to say.
    /// ``PhotoDiscoveryController/Phase/unsupported`` would tell the hiker a
    /// route stamped at every point has no clock.
    @Test("a hike gone from the store writes nothing, not that its route has no clock")
    func hikeGoneFromTheStoreWritesNothing() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        try context.save()
        let elsewhere = ModelContext(context.container)
        let row = try #require(try HikePhotoSearchPlan.SourceRead.fetchHike(elsewhere, hike.persistentModelID))
        elsewhere.delete(row)
        try elsewhere.save()
        try #require(hike.isAttached, "the search's own context has not merged the deletion")

        let controller = PhotoDiscoveryController(reader: library)
        await controller.search(in: hike)

        #expect(controller.phase == .searching)
        #expect(library.calls.withLock(\.accessRequests) == 0)
    }

    /// A day later, in route steps.
    private static let walkDay = 24.0 * 60

    /// The recorded fixture route, walked again from end to end a day later.
    private static func walkedHike(in context: ModelContext) -> Hike {
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let length = RouteProfile(route: PhotoDiscoveryFixture.route).totalDistanceMeters
        let walk = PhotoDiscoveryFixture.walk(
            hikeID: hike.id,
            fromStep: walkDay,
            toStep: walkDay + 9,
            covering: 0...length,
            routeDistanceMeters: length
        )
        context.insert(walk)
        walk.hike = hike
        return hike
    }

    /// The sheet starts a search when it opens, and the picker for a limited
    /// library starts another; the first can still be fetching or matching
    /// when the second has already answered. Whichever finishes last, the
    /// sheet shows the newest search's answer.
    @Test("a search overtaken by a newer one writes nothing")
    func overtakenSearchDropsItsAnswer() async throws {
        let dayLater: TimeInterval = 86_400
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("first", atStep: 2),
                PhotoLibraryAsset(
                    localIdentifier: "second",
                    createdAt: PhotoDiscoveryFixture.date(atStep: 2).addingTimeInterval(dayLater),
                    coordinate: nil
                ),
            ],
            fetchGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let first = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let second = Fixture.hike(
            in: context,
            route: PhotoDiscoveryFixture.route.map { point in
                RouteCoordinate(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    elevation: nil,
                    timestamp: point.timestamp?.addingTimeInterval(dayLater)
                )
            }
        )

        let overtaken = Task { @MainActor in await controller.search(in: first) }
        await settleDelegateHop(until: "the first search to reach the library fetch") {
            gate.isHolding
        }
        // The gate holds only the first fetch, so this one runs to the end.
        await controller.search(in: second)
        #expect(controller.matches.map(\.id) == ["second"])

        gate.open()
        await overtaken.value

        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["second"])
        #expect(controller.selection == ["second"])
    }

    @Test("a reopened search withdraws old results before indexing suspends")
    func reopenedSearchWithdrawsOldResults() async throws {
        let builds = Mutex(0)
        let isIndexing = Mutex(false)
        let indexing = DispatchSemaphore(value: 0)
        defer { indexing.signal() }
        let work = PhotoDiscoveryWork(
            fetchHike: PhotoDiscoveryWork.standard.fetchHike,
            buildPlan: { source in
                let count = builds.withLock { total in
                    total += 1
                    return total
                }
                if count == 2 {
                    isIndexing.withLock { $0 = true }
                    indexing.wait()
                }
                return PhotoDiscoveryWork.standard.buildPlan(source)
            },
            matchAssets: PhotoDiscoveryWork.standard.matchAssets
        )
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library, work: work)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        #expect(controller.canImport)

        let reopened = Task { @MainActor in await controller.search(in: hike) }
        await settleDelegateHop(until: "the reopened search to begin indexing") {
            isIndexing.withLock { $0 }
        }

        #expect(controller.phase == .searching)
        #expect(controller.matches.isEmpty)
        #expect(controller.selection.isEmpty)
        #expect(!controller.canImport)

        indexing.signal()
        await reopened.value
        #expect(controller.phase == .results)
        #expect(controller.selection == ["a"])
    }
}
