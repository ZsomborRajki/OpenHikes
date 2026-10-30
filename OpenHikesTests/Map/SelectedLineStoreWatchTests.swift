//
//  SelectedLineStoreWatchTests.swift
//  OpenHikesTests
//
//  A line saved for the followed hike through another context is noticed,
//  brought into the main context's hike and reported (#1228). Nothing else is
//  reported: a rename, another hike's line, the same line written again, or a
//  save of the other store.
//
//  The import is a sibling context's save, made off the main actor under the
//  mirroring delegate's author. As far as the watch can see, that posts what
//  the mirroring import posts: one remote change for the store and one history
//  transaction naming `route`. This was measured against a Core Data context
//  on SwiftData's own coordinator, which is as near to that import as a suite
//  can come. So the signal is the store's own and has no seam. The one seam
//  is the read of the stored line, which counts the decodes history is there
//  to spare.
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
    /// The stored-line reads the checks made, and whether each ran on the
    /// main thread.
    nonisolated final class ReadLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var count: Int { threads.withLock { $0.count } }
        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func read(_ context: ModelContext, _ hikeID: UUID) -> SelectedLineStoreCheck.StoredLine? {
            threads.withLock { $0.append(Thread.isMainThread) }
            return SelectedLineStoreCheck.storedLine(context, hikeID)
        }
    }

    /// Every remote change posted while a test runs, by store, so a test can
    /// wait for the one it caused to have been delivered.
    final class RemoteChanges {
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
    }

    /// One way another device can replace the line, each a change only the
    /// whole line can show: the points moved, only their heights, or only a
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
        let watch: SelectedLineStoreWatch
        let reads: ReadLog
        let reports: Reports
    }

    /// The hikes `lineReplaced` was called with, in order.
    final class Reports {
        private(set) var hikes: [UUID] = []

        func record(_ hike: Hike) { hikes.append(hike.id) }
    }

    /// Where the stores go: emptied once per run, never during one — see
    /// `StoreSandbox` for why.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "selected-line-watch", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    /// Both stores on disk, as the app opens them. History is the store's,
    /// and the in-memory store records some writes differently.
    private static func container() throws -> ModelContainer {
        let directory = sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
    }

    /// A saved hike followed by a watch, as the selection's readers would
    /// leave it, and a neighbor in the same store. Autosave is off so that
    /// an unsaved edit stays unsaved until a test saves it.
    private func stage() throws -> Stage {
        let container = try Self.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let hike = Fixture.hike(in: main, title: "Followed", route: Self.original)
        let neighbor = Fixture.hike(in: main, title: "Neighbor", route: Self.original)
        try main.save()
        let reads = ReadLog()
        let reports = Reports()
        let watch = SelectedLineStoreWatch(read: reads.read) { reports.record($0) }
        let readAt = Date.now
        watch.follow(hike, holding: hike.route, readAt: readAt)
        return Stage(container: container, hike: hike, neighbor: neighbor, watch: watch, reads: reads, reports: reports)
    }

    /// Another context's save, made as the mirroring import makes its own:
    /// off the main actor, under the import's author.
    @concurrent
    nonisolated private static func saveElsewhere(
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
    ) async -> SelectedLineStoreCheck.StoredLine? {
        SelectedLineStoreCheck.storedLine(ModelContext(container), hikeID)
    }

    /// Waits until a check has landed after the `checks` that had landed
    /// before, with nothing queued behind it.
    private func settle(_ watch: SelectedLineStoreWatch, after checks: Int) async {
        await settleDelegateHop(until: "the watch has checked the store") {
            watch.completedChecks > checks && watch.isSettled
        }
    }

    @Test("a line saved elsewhere is brought into the hike and reported once", arguments: Edit.allCases)
    func aLineSavedElsewhereIsReported(edit: Edit) async throws {
        let stage = try stage()
        let route = edit.route

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: route) }
        await settleDelegateHop(until: "the watch reports the new line") {
            stage.reports.hikes.count == 1 && stage.watch.isSettled
        }

        #expect(stage.reports.hikes == [stage.hike.id])
        #expect(stage.hike.route == route, "the main context's copy holds the new line")
        #expect(stage.hike.lineRevision == 1, "and its readers are told")
        #expect(stage.reads.ranOnMainThread == [false], "one read of the stored line, off the main thread")
    }

    @Test("a check reads only what is new: another hike's save after a reported line reads nothing")
    func aCheckStartsAfterTheLastOne() async throws {
        let stage = try stage()
        let moved = Edit.moved.route
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the watch reports the new line") {
            stage.reports.hikes.count == 1 && stage.watch.isSettled
        }
        let checks = stage.watch.completedChecks

        try await Self.saveElsewhere(stage.neighbor.id, in: stage.container) { $0.title = "Renamed elsewhere" }
        await settle(stage.watch, after: checks)

        #expect(stage.reads.count == 1, "the line's transaction is behind the token now")
        #expect(stage.reports.hikes.count == 1)
    }

    @Test("a rename saved elsewhere is read, found the same line and not reported")
    func aRenameIsNotReported() async throws {
        let stage = try stage()

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.title = "Renamed elsewhere" }
        await settle(stage.watch, after: 0)

        #expect(stage.reads.count == 1, "the hike's row was saved, and history cannot say which column")
        #expect(stage.reports.hikes.isEmpty)
        #expect(stage.hike.lineRevision == 0)
    }

    @Test("the same line saved again elsewhere is read, found equal and not reported")
    func theSameLineSavedAgainIsNotReported() async throws {
        let stage = try stage()

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: Self.original) }
        await settle(stage.watch, after: 0)

        #expect(stage.reads.count == 1, "the hike's row was saved")
        #expect(stage.reports.hikes.isEmpty)
        #expect(stage.hike.lineRevision == 0)
    }

    @Test("another hike's line saved elsewhere reads nothing and reports nothing")
    func anotherHikesLineIsNotReported() async throws {
        let stage = try stage()
        let moved = Edit.moved.route

        try await Self.saveElsewhere(stage.neighbor.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage.watch, after: 0)

        #expect(stage.reads.count == 0)
        #expect(stage.reports.hikes.isEmpty)
    }

    @Test("a save of the other store, or of a hike no longer followed, starts no check")
    func savesThatCannotMatterStartNoCheck() async throws {
        let stage = try stage()
        let moved = Edit.moved.route
        let changes = RemoteChanges()
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
        #expect(stage.watch.check == nil && stage.watch.completedChecks == 0)

        // And the followed hike's own store, once it is not followed.
        stage.watch.stopFollowing()
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the hike store's change is delivered") { changes.posted(hikesStore) }
        await settleDelegateHop()
        #expect(stage.watch.deliveredChanges == 0)
        #expect(stage.watch.check == nil && stage.watch.completedChecks == 0)
        #expect(stage.reports.hikes.isEmpty)
    }

    @Test("a hike the watch moved on from is not reported")
    func aHikeNoLongerFollowedIsNotReported() async throws {
        let stage = try stage()
        let moved = Edit.moved.route
        stage.watch.follow(stage.neighbor, holding: stage.neighbor.route, readAt: .now)

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage.watch, after: 0)

        #expect(stage.reads.count == 0, "the store's change was checked against the neighbor")
        #expect(stage.reports.hikes.isEmpty)
    }

    @Test("an unsaved edit holds the report until it saves, and the store's line then wins")
    func anUnsavedEditWaitsForItsSave() async throws {
        let stage = try stage()
        let moved = Edit.moved.route
        stage.hike.tintHex = "#FF0000"

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        await settle(stage.watch, after: 0)
        #expect(stage.reports.hikes.isEmpty, "a fetch cannot refresh a hike with unsaved changes")
        #expect(stage.hike.route == Self.original)

        try stage.container.mainContext.save()
        await settle(stage.watch, after: 1)

        // Measured on iOS 18.6 and 27: that save writes its snapshot's line
        // back, so the store ends on the original, and there is nothing to
        // report. Should a later SwiftData keep the received line instead,
        // the report follows. Either way the hike holds what the store holds.
        let stored = try #require(await Self.storedLine(of: stage.hike.id, in: stage.container)).route
        #expect(stage.hike.route == stored)
        #expect(stage.reports.hikes.count == (stored == Self.original ? 0 : 1))
        #expect(stage.reads.count == 2, "the save's check compares whatever history says")
    }

    @Test("a line written through the main context is read once more and left to its readers")
    func aLocalWriteOvertakesTheCheck() async throws {
        let stage = try stage()

        stage.hike.replaceRoute(with: Edit.moved.route)
        try stage.container.mainContext.save()
        await settle(stage.watch, after: 0)

        #expect(stage.reads.count == 1, "the main context writes under no author, so its write is compared too")
        #expect(stage.reports.hikes.isEmpty)
        #expect(stage.hike.lineRevision == 1, "moved once, by the write itself")
    }

    @Test("two lines saved in a row end with the hike holding the second")
    func linesSavedInARowEndOnTheLast() async throws {
        let stage = try stage()
        let moved = Edit.moved.route
        let heights = Edit.heights.route

        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: moved) }
        try await Self.saveElsewhere(stage.hike.id, in: stage.container) { $0.replaceRoute(with: heights) }
        await settleDelegateHop(until: "the hike holds the second line") {
            stage.watch.isSettled && !stage.reports.hikes.isEmpty && stage.hike.route == heights
        }

        #expect(stage.hike.lineRevision == stage.reports.hikes.count, "every report moved the revision once")
    }
}
