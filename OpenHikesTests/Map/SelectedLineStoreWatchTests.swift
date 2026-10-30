//
//  SelectedLineStoreWatchTests.swift
//  OpenHikesTests
//
//  A save of the followed hike's row through another context refreshes that
//  hike in its own context, and has the selected line looked at again (#1228).
//  As far as this device's store can tell, that save is what an edit mirrored
//  in from another device is. A save of anything else is not looked at:
//  another hike, the other store, a hike no longer followed. A check that a
//  selection change overtakes changes nothing.
//
//  The import is a sibling context's save, made off the main actor under the
//  mirroring delegate's author. As far as the watch can see, that posts what
//  the mirroring import posts: one remote change for the store and one
//  history transaction for the row. This was measured against a Core Data
//  context on SwiftData's own coordinator, which is as near to that import as
//  a suite can come. So the signal is the store's own and has no seam.
//
//  What a reader is handed is asserted through a stand-in reader, which arms
//  its watch through `SelectedLine` and reads again on every notification,
//  as the four readers in the app do. The selected line's fetches are counted
//  through its seam: each one is a decode of the stored line.
//

import CoreData
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@Suite("Selected line store watch")
struct SelectedLineStoreWatchTests {
    /// One way another device can replace the line, each a change only the
    /// whole line shows: the points moved, only their heights, or only a
    /// pause.
    enum Edit: String, CaseIterable, Sendable {
        case moved = "moved"
        case heights = "heights"
        case pause = "pause"

        var route: [RouteCoordinate] {
            SelectedLineStoreWatchTests.original.enumerated().map { index, point in
                var point = point
                switch self {
                case .moved: point.longitude += 0.01
                case .heights: point.elevation = (point.elevation ?? 0) + 120
                case .pause: point.boundary = index == 3 ? .paused : nil
                }
                return point
            }
        }
    }

    nonisolated static let original = (0..<6).map { index in
        RouteCoordinate(
            latitude: 47.63,
            longitude: 12.86 + Double(index) * 0.001,
            elevation: 500 + Double(index) * 10
        )
    }

    private struct Stage {
        let container: ModelContainer
        let hike: Hike
        let neighbor: Hike
        let lines: SelectedLine
        let fetches: StoreWatchFetchLog
        let reader: StoreWatchReader
        let looks: LookCount
        let watch: SelectedLineStoreWatch
    }

    /// Where the stores go: emptied once per run, never during one — see
    /// `StoreSandbox` for why.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "selected-line-watch", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// Both stores on disk, as the app opens them: the in-memory store was
    /// measured to keep a different history of an identical write.
    private static func container() throws -> ModelContainer {
        let directory = sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
    }

    /// A saved hike selected as the app selects one: read by a reader, then
    /// followed from the moment that read began, with a neighbor in the same
    /// store. Autosave is off, so an unsaved edit stays unsaved until a test
    /// saves it.
    private func stage(making: SelectedLineStoreCheck.Making? = nil) async throws -> Stage {
        let container = try Self.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let hike = Fixture.hike(in: main, title: "Followed", route: Self.original)
        let neighbor = Fixture.hike(in: main, title: "Neighbor", route: Self.original)
        try await RemoteChangeLog.save(main, settling: hike)
        let fetches = StoreWatchFetchLog()
        let lines = SelectedLine(fetch: fetches.fetch)
        let reader = StoreWatchReader(lines, reading: hike)
        _ = await reader.line
        let looks = LookCount()
        let watch = SelectedLineStoreWatch(making: making ?? SelectedLineStoreCheck.answer) {
            looks.record()
            lines.refresh()
        }
        watch.follow(hike, since: try #require(lines.readBegan(for: hike)))
        return Stage(
            container: container,
            hike: hike,
            neighbor: neighbor,
            lines: lines,
            fetches: fetches,
            reader: reader,
            looks: looks,
            watch: watch
        )
    }

    /// Another context's save, made as the mirroring import makes its own:
    /// off the main actor, under the import's author.
    @concurrent
    nonisolated static func saveElsewhere(
        _ hikeID: UUID,
        in container: ModelContainer,
        _ edit: @Sendable (Hike) -> Void
    ) async throws {
        let context = ModelContext(container)
        context.author = "NSCloudKitMirroringDelegate.import"
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        let hike = try #require(try context.fetch(descriptor).first)
        edit(hike)
        try context.save()
    }

    @concurrent
    nonisolated private static func storedLine(
        of hikeID: UUID,
        in container: ModelContainer
    ) async throws -> [RouteCoordinate] {
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        return try #require(try ModelContext(container).fetch(descriptor).first).route
    }

    /// Waits until a check has landed after the `checks` that had landed
    /// before, with nothing queued behind it, and for any look it started.
    private func settle(_ stage: Stage, after checks: Int) async {
        await settleDelegateHop(until: "the watch has checked the store") {
            stage.watch.completedChecks > checks && stage.watch.isSettled
        }
        await stage.lines.refreshing?.value
    }

    @Test("a line saved elsewhere reaches the selected line's reader, once", arguments: Edit.allCases)
    func aLineSavedElsewhereReachesTheReader(edit: Edit) async throws {
        let stage = try await stage()
        let route = edit.route

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: route) }
        await settleDelegateHop(until: "the reader hears of the new line") { stage.reader.heard == 1 }
        await settle(stage, after: 0)

        #expect(await stage.reader.line == route)
        #expect(stage.hike.route == route, "the main context's copy holds the stored line")
        #expect(stage.looks.count == 1)
        #expect(stage.reader.heard == 1)
        #expect(stage.fetches.ranOnMainThread == [false, false], "the selection's read, then the refresh's")
    }

    @Test("a rename saved elsewhere is looked at, and hands out nothing")
    func aRenameHandsOutNothing() async throws {
        let stage = try await stage()

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.title = "Renamed elsewhere" }
        await settle(stage, after: 0)

        #expect(stage.looks.count == 1, "the hike's row was saved, and history cannot say which column")
        #expect(stage.reader.heard == 0)
    }

    @Test("the same line saved again elsewhere is looked at, and hands out nothing")
    func theSameLineHandsOutNothing() async throws {
        let stage = try await stage()

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: Self.original) }
        await settle(stage, after: 0)

        #expect(stage.looks.count == 1)
        #expect(stage.reader.heard == 0)
    }

    @Test("another hike's line saved elsewhere is not looked at")
    func anotherHikesSaveIsNotLookedAt() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route

        try await Self.saveElsewhere(stage.neighbor.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage, after: 0)

        #expect(stage.looks.count == 0)
        #expect(stage.fetches.count == 1, "only the selection's read")
    }

    @Test("a check reads only what is new: another hike's save after a looked-at line looks at nothing")
    func aCheckStartsAfterTheLastOne() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the reader hears of the new line") { stage.reader.heard == 1 }
        await settle(stage, after: 0)
        let checks = stage.watch.completedChecks

        try await Self.saveElsewhere(stage.neighbor.id, in: stage.container) { $0.title = "Renamed elsewhere" }
        await settle(stage, after: checks)

        #expect(stage.looks.count == 1, "the line's transaction is behind the token now")
    }

    @Test("a save of the other store, or of a hike no longer followed, starts no check")
    func savesThatCannotMatterStartNoCheck() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route
        let changes = RemoteChangeLog()
        changes.start()
        defer { changes.stop() }

        // A device-local field: its row lives in the unmirrored store, which
        // this save creates.
        stage.hike.autoSaveTilesEnabled = false
        try stage.container.mainContext.save()
        let localStore = try #require(stage.hike.localState?.persistentModelID.storeIdentifier)
        let hikesStore = try #require(stage.hike.persistentModelID.storeIdentifier)
        #expect(localStore != hikesStore, "precondition: two stores")
        await settleDelegateHop(until: "the local store's change is delivered") { changes.posted(localStore) }
        await settleDelegateHop()
        #expect(stage.watch.deliveredChanges == 0, "dropped on the thread that posted it")
        #expect(stage.watch.completedChecks == 0)

        // And the followed hike's own store, once it is not followed.
        stage.watch.stopFollowing()
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the hike store's change is delivered") { changes.posted(hikesStore) }
        await settleDelegateHop()
        #expect(stage.watch.deliveredChanges == 0)
        #expect(stage.watch.completedChecks == 0)
        #expect(stage.looks.count == 0)
    }

    @Test("a hike the watch moved on from is not looked at")
    func aHikeNoLongerFollowedIsNotLookedAt() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route
        stage.watch.follow(stage.neighbor, since: .now)

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage, after: 0)

        #expect(stage.looks.count == 0)
        #expect(stage.hike.route == Self.original, "and its copy is left as it was")
    }

    @Test("a check overtaken by a change of selection, or by letting go, changes nothing", arguments: [false, true])
    func aCheckOvertakenChangesNothing(lettingGo: Bool) async throws {
        let held = HeldStoreCheck()
        let stage = try await stage(making: held.making)
        let moved = Edit.moved.route

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the check is in flight") { held.arrived == 1 }
        if lettingGo {
            stage.watch.stopFollowing()
        } else {
            stage.watch.follow(stage.neighbor, since: .now)
        }
        held.open()
        await settle(stage, after: 0)

        #expect(stage.looks.count == 0)
        #expect(stage.hike.route == Self.original, "the hike left behind is not refreshed")
        #expect(stage.reader.heard == 0)
    }

    @Test("an unsaved edit holds the look until it saves, and the store's line then wins")
    func anUnsavedEditWaitsForItsSave() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route
        stage.hike.tintHex = "#FF0000"

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage, after: 0)
        #expect(stage.looks.count == 0, "a fetch cannot refresh a hike with unsaved changes")
        #expect(stage.hike.route == Self.original)

        try stage.container.mainContext.save()
        await settle(stage, after: 1)

        // Measured on iOS 18.6 and 27: that save writes its snapshot's line
        // back, so the store ends on the original, and nothing new reaches the
        // reader. Should a later SwiftData keep the received line instead, it
        // reaches the reader. Either way the reader and the hike hold what the
        // store holds.
        let stored = try await Self.storedLine(of: stage.hike.id, in: stage.container)
        #expect(stage.looks.count == 1)
        #expect(stage.hike.route == stored)
        #expect(await stage.reader.line == stored)
        #expect(stage.reader.heard == (stored == Self.original ? 0 : 1))
    }

    @Test("a line written through the main context costs one look, and no second draw")
    func aLocalWriteIsDrawnOnce() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route

        stage.hike.replaceRoute(with: moved)
        try stage.container.mainContext.save()
        await settle(stage, after: 0)

        #expect(stage.looks.count == 1, "the main context writes under no author, so its save is looked at too")
        #expect(stage.reader.heard == 1, "heard once, from the write itself")
        #expect(await stage.reader.line == moved)
    }

    @Test("two lines saved in a row end with the reader holding the second")
    func linesSavedInARowEndOnTheLast() async throws {
        let stage = try await stage()
        let moved = Edit.moved.route
        let heights = Edit.heights.route

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: heights) }
        await settleDelegateHop(until: "the hike holds the second line") {
            stage.watch.isSettled && stage.reader.heard > 0 && stage.hike.route == heights
        }
        await stage.lines.refreshing?.value

        #expect(await stage.reader.line == heights)
    }
}

/// The selected line's fetches, and whether each ran on the main thread.
nonisolated private final class StoreWatchFetchLog: Sendable {
    private let threads = Mutex<[Bool]>([])

    var count: Int { threads.withLock { $0.count } }
    var ranOnMainThread: [Bool] { threads.withLock { $0 } }

    func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
        threads.withLock { $0.append(Thread.isMainThread) }
        return try SelectedLine.fetchHike(context, id)
    }
}

/// A reader of the selected line, reading it as the app's four do: the
/// watch armed first, then the line asked for, and both again whenever
/// the watch hears of a new line.
private final class StoreWatchReader {
    private let lines: SelectedLine
    private let hike: Hike
    private var write: SelectedLine.Write?
    private(set) var heard = 0
    private(set) var read: SelectedLine.Read?

    init(_ lines: SelectedLine, reading hike: Hike) {
        self.lines = lines
        self.hike = hike
        follow()
    }

    var line: [RouteCoordinate] {
        get async { await read?.route ?? [] }
    }

    private func follow() {
        write = lines.watch(hike) { [weak self] write in self?.lineDidChange(write) }
        read = lines.read(of: hike)
    }

    private func lineDidChange(_ write: SelectedLine.Write) {
        guard write === self.write else { return }
        heard += 1
        follow()
    }
}

/// A check held at its start until the test opens it, so a selection can
/// move on while it is in flight.
nonisolated private final class HeldStoreCheck: Sendable {
    private let gate = Mutex<(isOpen: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
    private let arrivals = Mutex(0)

    var arrived: Int { arrivals.withLock { $0 } }

    func making(_ request: SelectedLineStoreCheck.Request) async -> SelectedLineStoreCheck.Answer {
        arrivals.withLock { $0 += 1 }
        await withCheckedContinuation { continuation in
            let isOpen = gate.withLock { state in
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
        return await SelectedLineStoreCheck.answer(request)
    }

    func open() {
        let waiting = gate.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Every remote change posted while a test runs, by store, so a test can
/// wait for the one it caused to have been delivered. Shared by the suites
/// that follow a hike in the store.
final class RemoteChangeLog {
    nonisolated private final class Stores: Sendable {
        private let ids = Mutex<[String]>([])

        func append(_ id: String) { ids.withLock { $0.append(id) } }

        func contains(_ id: String) -> Bool { ids.withLock { $0.contains(id) } }
    }

    private let stores = Stores()
    private var observer: (any NSObjectProtocol)?

    func start() {
        let seen = stores
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let store = notification.userInfo?[NSStoreUUIDKey] as? String else { return }
            seen.append(store)
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func posted(_ store: String) -> Bool { stores.contains(store) }

    /// Saves `context`, and waits until the remote change that save posts
    /// for `hike`'s store has been delivered. The store posts a main
    /// context's change off the main thread after the save returns, so
    /// without this it can reach a watch armed a moment later.
    static func save(_ context: ModelContext, settling hike: Hike) async throws {
        let log = RemoteChangeLog()
        log.start()
        defer { log.stop() }
        try context.save()
        let store = try #require(hike.persistentModelID.storeIdentifier)
        await settleDelegateHop(until: "the save's remote change is delivered") { log.posted(store) }
    }
}

/// How many times the watch had the line looked at.
private final class LookCount {
    private(set) var count = 0

    func record() { count += 1 }
}
