//
//  PhotoDiscoveryControllerTests+OffMain.swift
//  OpenHikesTests
//
//  Where a search's route-sized work runs, and which search gets to write.
//
//  The controller is main-actor isolated, and it used to build the plan's
//  indexes and match the library's whole answer synchronously in its own
//  `search(in:)` — most of a second on a long, walked trail, with the sheet
//  frozen in front of it (#1119). Asserted through the work seam rather than
//  a stopwatch, as `HikeIntentLibrarySweepTests` asserts its read: each step
//  records the thread it ran on, and the caller is the main actor itself, so
//  a step that stays on its caller's executor fails.
//
//  Moving the match behind an `await` opens a window the synchronous one
//  never had, so the second test pins who may close it: only the newest
//  search writes.
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension for the reason
//  the other halves are: one test type per file, and these share every
//  fixture with the tests next door.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// Which threads each step of a search ran on, one entry per call.
    nonisolated final class WorkLog: Sendable {
        private let threads = Mutex<(plans: [Bool], matches: [Bool])>(([], []))

        var plansOnMainThread: [Bool] { threads.withLock(\.plans) }
        var matchesOnMainThread: [Bool] { threads.withLock(\.matches) }

        /// The real work, recording where each step ran before doing it.
        var work: PhotoDiscoveryWork {
            PhotoDiscoveryWork(
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
}
