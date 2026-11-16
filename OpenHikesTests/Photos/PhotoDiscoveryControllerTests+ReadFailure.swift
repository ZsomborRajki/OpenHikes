//
//  PhotoDiscoveryControllerTests+ReadFailure.swift
//  OpenHikesTests
//
//  A search whose read of the hike fails (#1442).
//
//  A fetch can fail, and a failure says nothing about the row: the hike is
//  still there, stamped at every point. The search used to read the failure
//  as a row that had gone, and stayed searching with nothing left to ask,
//  while the watch on the store's saves could not ask either, because it
//  looked only at a search that had a plan. A hike that has gone still writes
//  nothing (`hikeGoneFromTheStoreWritesNothing`, next door).
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension for the reason
//  the other halves are: one test type per file, and these share every
//  fixture with the tests next door.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// A store whose fetch fails until a test lets it read, and counts every
    /// fetch it is asked for.
    nonisolated final class FailingStore: Sendable {
        private let state = Mutex<(fails: Bool, fetches: Int)>((true, 0))

        var fetches: Int { state.withLock(\.fetches) }

        /// Every fetch from now on reads the store.
        func recover() { state.withLock { $0.fails = false } }

        var work: PhotoDiscoveryWork {
            PhotoDiscoveryWork(
                fetchHike: { context, id in
                    let fails = self.state.withLock { state in
                        state.fetches += 1
                        return state.fails
                    }
                    if fails { throw CocoaError(.fileReadUnknown) }
                    return try PhotoDiscoveryWork.standard.fetchHike(context, id)
                },
                buildPlan: PhotoDiscoveryWork.standard.buildPlan,
                matchAssets: PhotoDiscoveryWork.standard.matchAssets
            )
        }
    }

    /// The sheet says it could not search rather than that the route has no
    /// clock, asks for no access it has no plan to use, and searches when
    /// asked again.
    @Test("a hike that could not be read ends the search, and asking again searches it")
    func unreadHikeEndsTheSearch() async throws {
        let store = FailingStore()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library, work: store.work)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)

        await controller.search(in: hike)

        #expect(controller.phase == .readFailed)
        #expect(!controller.canImport)
        #expect(library.calls.withLock(\.accessRequests) == 0)

        store.recover()
        await controller.searchAgain(in: hike)

        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["a"])
    }

    /// Asking again is the failure's alone: after a search that read the
    /// hike, it starts nothing, and the review stands as the hiker left it.
    @Test("asking again after a search that read the hike starts nothing")
    func askingAgainNeedsAFailedRead() async throws {
        let log = WorkLog()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library, work: log.work)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)
        controller.toggle("a")

        await controller.searchAgain(in: hike)

        #expect(log.plansOnMainThread.count == 1)
        #expect(controller.phase == .results)
        #expect(controller.selection.isEmpty)
    }

    /// The sheet's watch looks once at once, which fails as well here, and
    /// only then can the hike be read and is the store saved.
    @Test("a save once the hike can be read searches it again")
    func saveAfterAFailedReadSearchesAgain() async throws {
        let store = FailingStore()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library, work: store.work)
        let container = try Self.containerOnDisk()
        let hike = try Self.savedHike(in: container.mainContext)
        let sheet = Self.sheetTask(controller, on: hike)
        await settleDelegateHop(until: "the watch's first look has failed too") { store.fetches >= 2 }
        #expect(controller.phase == .readFailed, "a look that fails leaves the sheet saying so")

        store.recover()
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.title = "Renamed" }
        await settleDelegateHop(until: "the photo is offered") { controller.phase == .results }
        sheet.cancel()
        await sheet.value

        #expect(controller.matches.map(\.id) == ["a"])
        #expect(controller.selection == ["a"])
    }
}
