//
//  LibraryLinesTests+FailedReads.swift
//  OpenHikesTests
//
//  A read that fails spends no invalidation, and a row that is gone owes no
//  line: see *A read that fails* in `LibraryLines.swift`.
//
//  A save here can wake the task twice, by its `didSave` and by its remote
//  change, so a hike that is owed can be asked for once more than the saves
//  alone would say. That one extra read is what these tests leave room for:
//  they count ``LibraryLines/retries`` and the hikes nothing owes.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension LibraryLinesTests {
    private struct FetchFailure: Error {}

    /// Three hikes drawn, with a new line saved for the first.
    private struct Refresh {
        let stage: LibraryLinesStage
        let edited: Hike
        let other: Hike
        let untouched: Hike
    }

    /// A ``Refresh``, whose read `script` has already said the outcome of.
    private static func refresh(script: (ReadLog, _ edited: UUID, _ other: UUID) -> Void) async throws -> Refresh {
        let stage = try LibraryLinesStage()
        let main = stage.container.mainContext
        let edited = Fixture.hike(in: main, title: "Edited")
        let other = Fixture.hike(in: main, title: "Other", route: Fixture.loopRoute)
        let untouched = Fixture.hike(in: main, title: "Untouched", route: Fixture.loopRoute)
        try main.save()
        stage.start()
        await settleDelegateHop(until: "the three hikes are drawn") { stage.library.lines.count == 3 }

        script(stage.reads, edited.id, other.id)
        edited.replaceRoute(with: Fixture.outAndBackRoute)
        try main.save()
        return Refresh(stage: stage, edited: edited, other: other, untouched: untouched)
    }

    /// Whether `hikeID`'s drawn line starts where `route` does.
    private static func draws(_ route: [RouteCoordinate], for hikeID: UUID, in stage: LibraryLinesStage) -> Bool {
        stage.library.line(of: hikeID)?.runs.first?.first?.latitude == route[0].latitude
    }

    /// The save that woke a pass may be the last there is. A save under a
    /// running follow can wake it a second time, which would read the line
    /// whether the failure asked for a pass or not. So this save is over, its
    /// remote change delivered, before the follow starts: nothing else is
    /// coming, and only the pass the failure asks for can draw the line.
    @Test("a refresh that fails is read again at once, with no other save")
    func aFailedRefreshIsReadAgainAtOnce() async throws {
        let stage = try LibraryLinesStage(onDisk: true)
        let main = stage.container.mainContext
        let edited = Fixture.hike(in: main, title: "Edited")
        let other = Fixture.hike(in: main, title: "Other", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(main, settling: edited)
        stage.start()
        await settleDelegateHop(until: "both hikes are drawn") { stage.library.lines.count == 2 }
        stage.stop()

        edited.replaceRoute(with: Fixture.outAndBackRoute)
        try await RemoteChangeLog.save(main, settling: edited)
        stage.reads.answer(edited.id, with: .failed, reads: 1)
        stage.start()
        defer { stage.stop() }
        await settleDelegateHop(until: "the new line is drawn") {
            Self.draws(Fixture.outAndBackRoute, for: edited.id, in: stage)
        }
        #expect(stage.library.retries == 1)
        #expect(stage.reads.count(of: other.id) == 2, "each follow's first pass, and nothing the failure asked for")
    }

    /// The case #1281 reported: the one more pass finds the failure still
    /// there, and the next pass names another row and nothing about this one.
    @Test("a refresh that still fails is read by a pass that names only another row")
    func aFailedRefreshIsReadByTheNextPass() async throws {
        let refresh = try await Self.refresh { reads, edited, other in
            reads.answer(edited, with: .failed, endedBy: other)
        }
        let stage = refresh.stage
        defer { stage.stop() }
        await settleDelegateHop(until: "the refresh and the pass it asked for both failed") {
            stage.reads.scriptedAnswers(for: refresh.edited.id) >= 2
        }

        refresh.other.replaceRoute(with: Fixture.ridgeRoute)
        try stage.container.mainContext.save()
        await settleDelegateHop(until: "both new lines are drawn") {
            Self.draws(Fixture.outAndBackRoute, for: refresh.edited.id, in: stage)
                && Self.draws(Fixture.ridgeRoute, for: refresh.other.id, in: stage)
        }
        #expect(stage.reads.count(of: refresh.untouched.id) == 1, "a save never reads the whole library")
    }

    @Test("a failure that holds keeps the old line and asks for one more pass, and no more")
    func aFailureThatHoldsAsksForOneMorePass() async throws {
        let refresh = try await Self.refresh { reads, edited, _ in
            reads.answer(edited, with: .failed)
        }
        let stage = refresh.stage
        defer { stage.stop() }
        await settleDelegateHop(until: "the refresh and the pass it asked for both failed") {
            stage.reads.scriptedAnswers(for: refresh.edited.id) >= 2
        }

        // Passes run one at a time, so a hike saved afterwards being drawn
        // says the pass that failed for the second time is over.
        let main = stage.container.mainContext
        let later = Fixture.hike(in: main, title: "Later")
        try main.save()
        await settleDelegateHop(until: "a hike saved afterwards is drawn") {
            stage.library.line(of: later.id) != nil
        }
        #expect(stage.library.retries == 1, "only the first failure asks for a pass")
        #expect(stage.reads.scriptedAnswers(for: refresh.edited.id) >= 3, "the later pass asked again")
        #expect(Self.draws(Fixture.ridgeRoute, for: refresh.edited.id, in: stage), "the old line stays drawn")
        #expect(stage.reads.count(of: refresh.untouched.id) == 1, "a save never reads the whole library")
    }

    /// Every pass asks for what is owed, so a hike still owed once its line
    /// had landed would cost every later save of the store a read of it.
    @Test("a line read after a failure is owed nothing more")
    func aLineReadAfterAFailureIsOwedNothing() async throws {
        let refresh = try await Self.refresh { reads, edited, _ in
            reads.answer(edited, with: .failed, reads: 1)
        }
        let stage = refresh.stage
        defer { stage.stop() }
        await settleDelegateHop(until: "the pass the failure asked for draws the new line") {
            Self.draws(Fixture.outAndBackRoute, for: refresh.edited.id, in: stage)
        }
        let asked = stage.reads.count(of: refresh.edited.id)

        refresh.other.replaceRoute(with: Fixture.ridgeRoute)
        try stage.container.mainContext.save()
        await settleDelegateHop(until: "the other hike's new line is drawn") {
            Self.draws(Fixture.ridgeRoute, for: refresh.other.id, in: stage)
        }
        #expect(stage.reads.count(of: refresh.edited.id) == asked, "a save of another row asks for it no more")
    }

    /// Listed still, as a hike deleted just after a listing is: whether the
    /// line is drawn is the next listing's to say, and a read of a row that
    /// is not there owes nothing.
    @Test("a row that is gone is not read again")
    func aRowThatIsGoneIsNotReadAgain() async throws {
        let refresh = try await Self.refresh { reads, edited, _ in
            reads.answer(edited, with: .gone)
        }
        let stage = refresh.stage
        defer { stage.stop() }
        await settleDelegateHop(until: "the refresh found no row") {
            stage.reads.scriptedAnswers(for: refresh.edited.id) == 1
        }

        let main = stage.container.mainContext
        let later = Fixture.hike(in: main, title: "Later")
        try main.save()
        await settleDelegateHop(until: "a hike saved afterwards is drawn") {
            stage.library.line(of: later.id) != nil
        }
        #expect(stage.library.retries == 0)
        #expect(stage.reads.count(of: refresh.edited.id) == 2, "the first read and the refresh")
    }

    @Test("the reader tells a row that is gone from a fetch that failed")
    func theReaderTellsGoneFromFailed() async throws {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext, route: Fixture.loopRoute)
        try container.mainContext.save()
        let missing = UUID()

        let read = await LibraryLines.readLines([hike.id, missing], in: container)

        let line = try #require(read[hike.id])
        guard case .line(let runs) = line, let start = runs.first?.first else {
            Issue.record("a hike with a row reads as \(line)")
            return
        }
        #expect(start.latitude == Fixture.loopRoute[0].latitude)
        let gone = try #require(read[missing])
        guard case .gone = gone else {
            Issue.record("a hike with no row reads as \(gone)")
            return
        }
        let failed = LibraryLines.lineRead { throw FetchFailure() }
        guard case .failed = failed else {
            Issue.record("a fetch that throws reads as \(failed)")
            return
        }
    }
}
