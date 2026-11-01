//
//  LibraryLinesTests.swift
//  OpenHikesTests
//
//  Every hike in the library reaches the map, and stays true to the store,
//  without a line being read twice for nothing. See `LibraryLines.swift`.
//
//  A line read again is counted by the hike it belongs to, through the
//  reading seam, so "nothing else was read" is a number rather than a timing.
//  A save through the main context is told by its own `didSave`; one by any
//  other context, as the mirroring import makes it, by the store's history,
//  which an in-memory store does not keep — so that test opens both stores on
//  disk, as the app does, and saves the way `SelectedLineStoreWatchTests`
//  does.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Synchronization
import Testing

@Suite("Library lines")
struct LibraryLinesTests {
    private static let hour: TimeInterval = 3600
    private static let red = "#FF0000"

    @Test("every finished hike's line is drawn, newest first, and a recording's draft is not")
    func everyFinishedHikeIsDrawn() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let older = Fixture.hike(in: main, title: "Older") { $0.date = .now - 2 * Self.hour }
        let newer = Fixture.hike(in: main, title: "Newer", route: Fixture.loopRoute) { $0.date = .now - Self.hour }
        let draft = Fixture.hike(in: main, title: "Draft", route: []) { $0.isRecording = true }
        try main.save()
        stage.start()
        defer { stage.stop() }

        await settleDelegateHop(until: "both finished hikes are drawn") { stage.library.lines.count == 2 }
        #expect(stage.library.lines.map(\.hikeID) == [newer.id, older.id])
        #expect(!stage.reads.calls.joined().contains(draft.id), "a draft has no line to read")
        let first = try #require(stage.library.lines.first?.runs.first?.first)
        #expect(first.latitude == Fixture.loopRoute[0].latitude)
        #expect(first.longitude == Fixture.loopRoute[0].longitude)
    }

    @Test("a hike deleted here goes from the map, and nothing is read for it")
    func aDeletedHikeGoes() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let kept = Fixture.hike(in: main, title: "Kept")
        let deleted = Fixture.hike(in: main, title: "Deleted")
        try main.save()
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "both hikes are drawn") { stage.library.lines.count == 2 }

        main.delete(deleted)
        try main.save()
        await settleDelegateHop(until: "the deleted hike's line goes") {
            stage.library.lines.map(\.hikeID) == [kept.id]
        }
        // The line goes before that pass reads anything, and passes run one
        // at a time, so a hike saved afterwards is what says it is over.
        let later = Fixture.hike(in: main, title: "Later")
        try main.save()
        await settleDelegateHop(until: "a hike saved afterwards is drawn") {
            stage.library.line(of: later.id) != nil
        }
        #expect(stage.reads.count(of: kept.id) == 1, "a delete names no other row")
        // Asked for again it can be: a pass already under way when the delete
        // is saved can have listed the library before it and take the deleted
        // row as saved after it, as one did on a busy runner. By then the row
        // is gone, so nothing comes back.
        #expect(stage.reads.linesRead(of: deleted.id) == 1, "nor is the hike it took read again")
    }

    /// Heights filled in, *Edit Route*, a recording finished: written and
    /// saved through the main context, which names the row.
    @Test("a line written here is read again, and no other")
    func aLineWrittenHereIsReadAgain() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let edited = Fixture.hike(in: main, title: "Edited")
        let other = Fixture.hike(in: main, title: "Other", route: Fixture.loopRoute)
        try main.save()
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "both hikes are drawn") { stage.library.lines.count == 2 }
        let before = try #require(stage.library.line(of: edited.id)).revision

        edited.replaceRoute(with: Fixture.outAndBackRoute)
        try main.save()
        await settleDelegateHop(until: "the new line is drawn") {
            stage.library.line(of: edited.id)?.revision != before
        }
        let start = try #require(stage.library.line(of: edited.id)?.runs.first?.first)
        #expect(start.latitude == Fixture.outAndBackRoute[0].latitude)
        #expect(stage.reads.count(of: edited.id) == 2)
        #expect(stage.reads.count(of: other.id) == 1, "a save names its own row and no other")
    }

    @Test("a new colour saved here is drawn")
    func aNewColorIsDrawn() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let tinted = Fixture.hike(in: main)
        try main.save()
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "the hike is drawn") { stage.library.lines.count == 1 }

        tinted.tintHex = Self.red
        try main.save()
        await settleDelegateHop(until: "its line takes the new colour") {
            stage.library.line(of: tinted.id)?.tintHex == Self.red
        }
    }

    /// A recording's draft has no line until Stop writes one, in one save
    /// with the flag that says it is a hike.
    @Test("a recording that stops is drawn")
    func aStoppedRecordingIsDrawn() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let finished = Fixture.hike(in: main, title: "Finished")
        let recording = Fixture.hike(in: main, title: "Recording", route: []) { $0.isRecording = true }
        try main.save()
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "the finished hike is drawn") { stage.library.line(of: finished.id) != nil }
        #expect(stage.library.line(of: recording.id) == nil)

        recording.replaceRoute(with: Fixture.ridgeRoute)
        recording.isRecording = false
        try main.save()
        await settleDelegateHop(until: "the finished recording is drawn") {
            stage.library.line(of: recording.id) != nil
        }
    }

    /// An edit mirrored in from the hiker's other device: another context's
    /// save under the import's author, which only the store's history names.
    @Test("a line saved elsewhere is read again, and no other")
    func aLineSavedElsewhereIsReadAgain() async throws {
        let stage = try LibraryLinesStage(onDisk: true)
        let main = stage.container.mainContext
        let edited = Fixture.hike(in: main, title: "Edited")
        let other = Fixture.hike(in: main, title: "Other", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(main, settling: edited)
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "both hikes are drawn") { stage.library.lines.count == 2 }
        let before = try #require(stage.library.line(of: edited.id)).revision

        try await SelectedLineStoreWatchTests.saveElsewhere(edited.id, in: stage.container) { hike in
            hike.replaceRoute(with: Fixture.outAndBackRoute)
        }
        await settleDelegateHop(until: "the imported line is drawn") {
            stage.library.line(of: edited.id)?.revision != before
        }
        let start = try #require(stage.library.line(of: edited.id)?.runs.first?.first)
        #expect(start.latitude == Fixture.outAndBackRoute[0].latitude)
        #expect(stage.reads.count(of: other.id) == 1)
    }

    /// A look that cannot read history cannot rule any row out, and taking
    /// that as every row saved would read the whole library again.
    @Test("history that cannot be read reads no line again")
    func unreadableHistoryReadsNothing() async throws {
        let looks = FailingLooks()
        let stage = try LibraryLinesStage(onDisk: true, checking: looks.look)
        let main = stage.container.mainContext
        let hikes = [Fixture.hike(in: main, title: "One"), Fixture.hike(in: main, title: "Two")]
        try await RemoteChangeLog.save(main, settling: hikes[0])
        stage.start()
        defer { stage.stop() }

        // The first failure asks for one more look at once, and the second
        // asks for nothing.
        await settleDelegateHop(until: "both hikes are drawn and a second look has failed") {
            stage.library.lines.count == 2 && looks.count >= 2
        }
        // The second look's pass decides what to read only after the look,
        // and right, it reads nothing to show for it: a hike saved afterwards
        // is what says that pass is over.
        let later = Fixture.hike(in: main, title: "Later")
        try main.save()
        await settleDelegateHop(until: "a hike saved afterwards is drawn") {
            stage.library.line(of: later.id) != nil
        }
        #expect(hikes.allSatisfy { stage.reads.count(of: $0.id) == 1 })
    }

    /// The map's view built again ends one task and starts another, and
    /// nothing watched the store in between: a line saved then is one the new
    /// task cannot be told about, so it reads them all.
    @Test("a new follow reads every line again, and keeps drawing the old ones meanwhile")
    func aNewFollowReadsEveryLineAgain() async throws {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let hikes = [Fixture.hike(in: main, title: "One"), Fixture.hike(in: main, title: "Two")]
        try main.save()
        stage.start()
        await settleDelegateHop(until: "both hikes are drawn") { stage.library.lines.count == 2 }
        stage.stop()
        let before = stage.library.lines.map(\.revision)

        // The new follow publishes what it listed before it reads, so its
        // read is held while that publication is looked at.
        stage.reads.hold()
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "the new follow is reading") { stage.reads.calls.count == 2 }
        #expect(stage.library.lines.map(\.revision) == before, "what was drawn stays drawn")
        stage.reads.release()
        await settleDelegateHop(until: "every line is read again") {
            hikes.allSatisfy { stage.reads.count(of: $0.id) == 2 }
                && stage.library.lines.map(\.revision) != before
        }
        #expect(Set(stage.library.lines.map(\.hikeID)) == Set(hikes.map(\.id)))
    }

    @Test("a tap on a line opens its hike the way its widget would")
    func aTapOpensTheHike() async throws {
        let stage = try LibraryLinesStage()
        let hikeID = UUID()
        var links = stage.openRequests.links().makeAsyncIterator()
        stage.library.open(hikeID: hikeID)
        let link = await links.next()
        #expect(link == TrailWidgetDeepLink.url(hikeID: hikeID))
    }
}

// MARK: - The stage

/// A library on a store of its own, its lines followed while a test runs.
@MainActor
private final class LibraryLinesStage {
    /// Where on-disk stores go: emptied once per run, never during one, for
    /// the reason `HikeListElevationStage` gives.
    private static let sandbox: URL = {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "library-lines", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        return root
    }()

    let container: ModelContainer
    let openRequests = HikeOpenRequests()
    let library: LibraryLines
    let reads = ReadLog()
    private let checking: StoreHistoryCheck.Making
    private var task: Task<Void, Never>?

    init(onDisk: Bool = false, checking: @escaping StoreHistoryCheck.Making = StoreHistoryCheck.answer) throws {
        if onDisk {
            let directory = Self.sandbox.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer.openHikes(
                url: directory.appending(path: "OpenHikes.store"),
                localURL: directory.appending(path: "OpenHikesLocal.store")
            )
        } else {
            container = try Fixture.modelContainer()
        }
        container.mainContext.autosaveEnabled = false
        library = LibraryLines(openRequests: openRequests)
        self.checking = checking
    }

    func start() {
        task = Task { [library, container, reads, checking] in
            await library.follow(in: container, reading: reads.read, checking: checking)
        }
    }

    func stop() {
        task?.cancel()
    }
}

private extension LibraryLines {
    func line(of hikeID: UUID) -> LibraryLine? {
        lines.first { $0.hikeID == hikeID }
    }
}

/// Every call the lines were read through, the hikes each asked for, and the
/// lines that came back.
nonisolated private final class ReadLog: Sendable {
    private let log = Mutex<[[UUID]]>([])
    /// The hikes a read came back with a line for: a hike deleted since the
    /// pass listed it has no row left to read.
    private let found = Mutex<[UUID]>([])
    /// What the next read waits on, once ``hold()`` asks for one to wait.
    private let held = Mutex<AsyncStream<Void>?>(nil)
    private let opener = Mutex<AsyncStream<Void>.Continuation?>(nil)

    var calls: [[UUID]] { log.withLock { $0 } }

    /// How many times `hikeID`'s line was asked for.
    func count(of hikeID: UUID) -> Int {
        calls.joined().count { $0 == hikeID }
    }

    /// How many times `hikeID`'s line was read: asked for, and there.
    func linesRead(of hikeID: UUID) -> Int {
        found.withLock { $0.count { $0 == hikeID } }
    }

    /// Makes the next read wait, logged but not yet read, until
    /// ``release()``. A cancelled task stops waiting too.
    func hold() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        held.withLock { $0 = stream }
        opener.withLock { $0 = continuation }
    }

    func release() {
        opener.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
    }

    @concurrent
    func read(_ hikeIDs: [UUID], in container: ModelContainer) async -> [UUID: [[CLLocationCoordinate2D]]] {
        log.withLock { $0.append(hikeIDs) }
        let gate = held.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        if let gate {
            for await _ in gate { /* nothing is sent: finishing it is the release */ }
        }
        let lines = await LibraryLines.readLines(hikeIDs, in: container)
        found.withLock { $0.append(contentsOf: lines.keys) }
        return lines
    }
}

/// A store whose history can never be read, as an expired token's cannot.
nonisolated private final class FailingLooks: Sendable {
    private let looks = Mutex(0)

    var count: Int { looks.withLock { $0 } }

    @concurrent
    func look(_ request: StoreHistoryCheck.Request) async -> StoreHistoryCheck.Answer {
        looks.withLock { $0 += 1 }
        return StoreHistoryCheck.Answer(token: nil, savedRows: request.rows, wasRead: false)
    }
}
