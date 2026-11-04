//
//  PhotoDiscoveryControllerTests+LineEdits.swift
//  OpenHikesTests
//
//  What a search offers, and what Add stores, once the hike has moved on from
//  the plan behind them (#1280).
//
//  Everything after a search reads its hike is a wait, and a line can land in
//  any of them: while the plan is indexed, while the library answers, while
//  the matcher runs, with the grid on screen, and between the photographs of
//  an import. The pins from before it used to go on being offered and stored,
//  the line a degree north of where the hike now ran. Each wait is held here
//  through a seam, so the edit is genuinely mid-flight rather than before or
//  after it, and each is run for a line written here and for one received
//  through another context, which moves no revision and refreshes nothing in
//  the hike's own copy.
//
//  The watch on the store runs on stores on disk, as the app opens them, so
//  the save that wakes it is a remote change SwiftData posted.
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
    /// The two steps a search runs off the main actor, held at their first
    /// call until a test has acted, and let straight through on every later
    /// one, so a search begun again runs to its end.
    nonisolated final class HeldStep: Sendable {
        private let calls = Mutex(0)
        private let released = DispatchSemaphore(value: 0)

        var isHolding: Bool { calls.withLock { $0 > 0 } }

        /// Blocks a concurrent step, which is off the main actor, so the test
        /// goes on running.
        func pass() {
            let isFirst = calls.withLock { count in
                count += 1
                return count == 1
            }
            if isFirst { released.wait() }
        }

        func release() { released.signal() }
    }

    /// Which wait in a search the line lands in.
    enum SearchWait: String, CaseIterable, Sendable {
        case indexing = "indexing"
        case library = "library"
        case matching = "matching"
    }

    private static let walkDay = 24.0 * 60

    /// Where a store on disk goes: emptied once per run, never during one —
    /// see `StoreSandbox` for why.
    private static let storesRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "photo-discovery-line-edits", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// Both stores on disk, as the app opens them. A test keeps the container
    /// for as long as it keeps a hike in it.
    private static func containerOnDisk() throws -> ModelContainer {
        let directory = storesRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
    }

    /// A search and the watch that follows it, as the sheet's task runs them.
    private static func sheetTask(_ controller: PhotoDiscoveryController, on hike: Hike) -> Task<Void, Never> {
        Task { @MainActor in
            await controller.search(in: hike)
            await controller.followSaves(of: hike)
        }
    }

    /// A hike its context has saved, so a search reads it from the store.
    private static func savedHike(
        in context: ModelContext,
        route: [RouteCoordinate] = PhotoDiscoveryFixture.route
    ) throws -> Hike {
        let hike = Fixture.hike(in: context, route: route)
        try context.save()
        return hike
    }

    /// Whether what the grid offers stands on the points `steps` along `route`.
    private static func offered(
        _ controller: PhotoDiscoveryController,
        stand steps: [Int],
        on route: [RouteCoordinate]
    ) -> Bool {
        PhotoDiscoveryFixture.pins(controller.matches.map(\.latitude), stand: steps, on: route)
    }

    @Test(
        "a line replaced during a search is the one its photos are offered on",
        arguments: SearchWait.allCases,
        PhotoLineEdit.allCases
    )
    func lineReplacedDuringASearch(wait: SearchWait, edit: PhotoLineEdit) async throws {
        let step = HeldStep()
        defer { step.release() }
        let gate = TestGate()
        let work = PhotoDiscoveryWork(
            fetchHike: PhotoDiscoveryWork.standard.fetchHike,
            buildPlan: { source in
                if wait == .indexing { step.pass() }
                return PhotoDiscoveryWork.standard.buildPlan(source)
            },
            matchAssets: { plan, assets, alreadyImported in
                if wait == .matching { step.pass() }
                return PhotoDiscoveryWork.standard.matchAssets(plan, assets, alreadyImported)
            }
        )
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)],
            fetchGate: wait == .library ? gate : nil
        )
        let controller = PhotoDiscoveryController(reader: library, work: work)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)

        let search = Task { @MainActor in await controller.search(in: hike) }
        await settleDelegateHop(until: "the search to reach the wait") { step.isHolding || gate.isHolding }
        try await edit.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        step.release()
        gate.open()
        await search.value

        #expect(controller.phase == .results)
        #expect(Self.offered(controller, stand: [2], on: PhotoDiscoveryFixture.movedRoute))
        #expect(controller.selection == ["a"])
    }

    /// The grid is up, nothing has noticed, and Add is tapped. Nothing on the
    /// line that went may be stored, and the photograph is not lost either:
    /// it is offered again where the new line puts it.
    @Test("Add stores no pin from a line that has gone", arguments: PhotoLineEdit.allCases)
    func addAfterTheLineMoved(edit: PhotoLineEdit) async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)
        try await edit.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)

        let added = await controller.importSelected(into: hike, store: sandbox.store)

        #expect(added == 0)
        #expect(hike.photos.isEmpty)
        #expect(controller.phase == .results)
        #expect(Self.offered(controller, stand: [2], on: PhotoDiscoveryFixture.movedRoute))

        #expect(await controller.importSelected(into: hike, store: sandbox.store) == 1)
        let stored = hike.photos.map(\.latitude)
        #expect(PhotoDiscoveryFixture.pins(stored, stand: [2], on: PhotoDiscoveryFixture.movedRoute))
    }

    /// The wait for a full-size asset is the longest there is, and it comes
    /// after Add was tapped, so a check made only at the tap would miss it.
    @Test("a line replaced while a photo's bytes load stores none of the selection", arguments: PhotoLineEdit.allCases)
    func lineReplacedWhileAPhotoLoads(edit: PhotoLineEdit) async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)

        let importing = Task { @MainActor in await controller.runImport(into: hike, store: sandbox.store) }
        await settleDelegateHop(until: "the import to reach the first photo's bytes") { gate.isHolding }
        try await edit.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        gate.open()
        let added = await importing.value

        #expect(added == 0)
        #expect(hike.photos.isEmpty)
        #expect(library.calls.withLock(\.dataReads) == 1, "the second photo is not read for a line that has gone")
        #expect(controller.phase == .results)
        #expect(controller.selection == ["a", "b"])
        #expect(Self.offered(controller, stand: [2, 5], on: PhotoDiscoveryFixture.movedRoute))
    }

    /// What landed before the line moved stays, where it landed, as every
    /// photo already on a hike stays through an edit. What had not is offered
    /// on the new line, and the one that landed is not offered again.
    @Test("a line replaced part-way through an import keeps what landed and offers the rest again")
    func lineReplacedPartWayThroughAnImport() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate,
            dataGateIdentifier: "b"
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)

        let importing = Task { @MainActor in await controller.runImport(into: hike, store: sandbox.store) }
        await settleDelegateHop(until: "the import to reach the second photo's bytes") { gate.isHolding }
        try await PhotoLineEdit.received.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        gate.open()
        let added = await importing.value

        #expect(added == 1)
        #expect(hike.photos.map(\.assetLocalIdentifier) == ["a"])
        #expect(PhotoDiscoveryFixture.pins(hike.photos.map(\.latitude), stand: [2], on: PhotoDiscoveryFixture.route))
        #expect(controller.phase == .results, "the Add button closes the sheet only on an empty one")
        #expect(controller.matches.map(\.id) == ["b"])
        #expect(Self.offered(controller, stand: [5], on: PhotoDiscoveryFixture.movedRoute))
    }

    /// A rebuilt offer is the same review carried on, not a new one: what the
    /// hiker took out stays out, even though results otherwise arrive ticked.
    /// And what they put back stays back, through the rebuild after that.
    @Test("a rebuilt offer leaves out what the hiker unticked")
    func rebuiltOfferKeepsWhatWasUnticked() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)
        controller.toggle("b")
        try await PhotoLineEdit.received.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)

        await controller.importSelected(into: hike, store: sandbox.store)

        #expect(controller.matches.map(\.id) == ["a", "b"])
        #expect(controller.selection == ["a"])

        controller.toggle("b")
        try await PhotoLineEdit.received.replaceLine(of: hike, with: PhotoDiscoveryFixture.route)
        await controller.importSelected(into: hike, store: sandbox.store)

        #expect(Self.offered(controller, stand: [2, 5], on: PhotoDiscoveryFixture.route))
        #expect(controller.selection == ["a", "b"])
    }

    /// Nothing has been tapped: a grid left up over a line that has gone says
    /// nothing is wrong, so the watch has to take it down by itself.
    @Test("a line received with the grid up rebuilds the grid", arguments: PhotoLineEdit.allCases)
    func lineReceivedWithTheGridUp(edit: PhotoLineEdit) async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let container = try Self.containerOnDisk()
        let hike = try Self.savedHike(in: container.mainContext)
        let sheet = Self.sheetTask(controller, on: hike)
        await settleDelegateHop(until: "the grid is up") { controller.phase == .results }

        try await edit.replaceLine(of: hike, with: PhotoDiscoveryFixture.movedRoute)
        await settleDelegateHop(until: "the grid has moved to the new line") {
            Self.offered(controller, stand: [2], on: PhotoDiscoveryFixture.movedRoute)
        }
        sheet.cancel()
        await sheet.value

        #expect(controller.phase == .results)
        #expect(controller.selection == ["a"])
    }

    /// The grid is not the only thing a line can overturn: a trail that could
    /// not be searched can be, once a walk along it arrives.
    @Test("a walk received under the sheet is searched")
    func walkReceivedIsSearched() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 4.5)])
        let controller = PhotoDiscoveryController(reader: library)
        let container = try Self.containerOnDisk()
        let hike = try Self.savedHike(in: container.mainContext, route: PhotoDiscoveryFixture.unstampedRoute)
        let sheet = Self.sheetTask(controller, on: hike)
        await settleDelegateHop(until: "the sheet says the route has no clock") { controller.phase == .unsupported }

        try await Self.saveWalk(on: hike, in: container)
        await settleDelegateHop(until: "the walk's photo is offered") { controller.phase == .results }
        sheet.cancel()
        await sheet.value

        #expect(controller.matches.map(\.evidence) == [.walk])
    }

    /// The walk is what placed the photograph, on a line that has not moved,
    /// so it is the only input that changed.
    @Test("Add stores no pin from a walk that has gone")
    func addAfterTheWalkWent() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 4.5)])
        let controller = PhotoDiscoveryController(reader: library)
        let container = try Self.containerOnDisk()
        let hike = try Self.savedHike(in: container.mainContext, route: PhotoDiscoveryFixture.unstampedRoute)
        try await Self.saveWalk(on: hike, in: container)
        await controller.search(in: hike)
        #expect(controller.matches.map(\.evidence) == [.walk])
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { row in
            for walk in row.walks ?? [] { row.modelContext?.delete(walk) }
        }

        let added = await controller.importSelected(into: hike, store: sandbox.store)

        #expect(added == 0)
        #expect(hike.photos.isEmpty)
        #expect(controller.phase == .unsupported)
    }

    /// A walk along the line, end to end, saved through another context.
    private static func saveWalk(on hike: Hike, in container: ModelContainer) async throws {
        let length = RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute).totalDistanceMeters
        let hikeID = hike.id
        try await SelectedLineStoreWatchTests.saveElsewhere(hikeID, in: container) { row in
            let walk = PhotoDiscoveryFixture.walk(
                hikeID: hikeID,
                fromStep: 0,
                toStep: 9,
                covering: 0...length,
                routeDistanceMeters: length
            )
            row.modelContext?.insert(walk)
            walk.hike = row
        }
    }

    /// What a save of the store must not do, with a review in progress:
    /// heights filled onto the line leave every point where it was, and a
    /// rename touches nothing a pin rests on. Each save is followed by one
    /// more, because the watch reads one save at a time: the second look
    /// begins only once the first has compared what it read, and whatever
    /// that started has ended.
    @Test("a save that moves no pin leaves the review alone", arguments: [true, false])
    func unrelatedSaveLeavesTheReviewAlone(fillsHeights: Bool) async throws {
        let log = WorkLog()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library, work: log.work)
        let container = try Self.containerOnDisk()
        let hike = try Self.savedHike(in: container.mainContext)
        let hikeID = hike.id
        let sheet = Self.sheetTask(controller, on: hike)
        await settleDelegateHop(until: "the grid is up") { controller.phase == .results }
        controller.toggle("b")
        await settleDelegateHop(until: "the watch's first look") { log.fetchesOnMainThread.count >= 3 }

        for name in ["First", "Second"] {
            let looked = log.fetchesOnMainThread.count
            try await SelectedLineStoreWatchTests.saveElsewhere(hikeID, in: container) { row in
                row.title = name
                if fillsHeights {
                    row.replaceRoute(with: row.route.map { point in
                        var point = point
                        point.elevation = 800
                        return point
                    })
                }
            }
            await settleDelegateHop(until: "the watch to look at the save") {
                log.fetchesOnMainThread.count > looked
            }
        }
        sheet.cancel()
        await sheet.value

        #expect(library.calls.withLock(\.fetches) == 1)
        #expect(controller.phase == .results)
        #expect(controller.selection == ["a"])
    }

    /// A store read per photograph, on top of the plan's own, is only fine
    /// off the main actor.
    @Test("what an import checks is read off the main thread")
    func importChecksLeaveTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let sandbox = PhotoStoreSandbox()
        let log = WorkLog()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library, work: log.work)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)

        #expect(await controller.importSelected(into: hike, store: sandbox.store) == 2)

        #expect(log.fetchesOnMainThread == [false, false, false, false], "the plan, the search's look, and one a photo")
        #expect(log.plansOnMainThread == [false], "a line that has not moved is read, and not indexed again")
    }

    /// Writing a photograph is the last wait before it is attached, so the
    /// look that decides whether its pin still holds comes after it: a line
    /// landing while the bytes are written is one the look finds.
    @Test("an import looks at the hike once each photo is on disk")
    func importLooksOnceEachPhotoIsOnDisk() async throws {
        let sandbox = PhotoStoreSandbox()
        let reads = PhotoReadsAgainstDisk(sandbox)
        let work = PhotoDiscoveryWork(
            fetchHike: reads.counting(PhotoDiscoveryWork.standard.fetchHike),
            buildPlan: PhotoDiscoveryWork.standard.buildPlan,
            matchAssets: PhotoDiscoveryWork.standard.matchAssets
        )
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library, work: work)
        let context = try Fixture.modelContext()
        let hike = try Self.savedHike(in: context)
        await controller.search(in: hike)

        #expect(await controller.importSelected(into: hike, store: sandbox.store) == 2)

        #expect(reads.photosOnDisk == [0, 0, 1, 2], "the plan, the search's look, then each photo's once it is written")
    }
}
