//
//  RouteEditChecksTests+Answers.swift
//  OpenHikesTests
//
//  What an answer may not do to the rest of the hike: lose an answer given
//  while the line was being drawn, leave a cut where the answer before it
//  put it, move when the walk began or ended, or be drawn from a trace this
//  device does not have yet. And a drive off the end with nothing else to
//  check can be looked at and kept, and a pull after an answer is bounded
//  by the junctions of the line the answer drew.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

extension RouteEditChecksTests {
    /// When the hiker pressed Start and Stop: before the first fix and after
    /// the last, as a recording's own walk keeps them.
    private enum Clock {
        static let pressedStart = Line.start.addingTimeInterval(-30)
        static let pressedStop = Line.start.addingTimeInterval(12 * Line.secondsPerPoint)
    }

    private static func snapped(_ id: Int, _ points: ClosedRange<Int>) -> RouteCheck {
        RouteCheck(id: id, kind: .snapped, savedChoice: .matched, savedRange: points, rawRange: points)
    }

    /// Two stretches moved onto the trail, apart.
    private static let twoChecks = RouteAssembly(
        pieces: [.kept(0...1), .check(1), .kept(3...6), .check(2), .kept(8...10)],
        checks: [snapped(1, 1...3), snapped(2, 6...8)]
    )

    /// The line's first and last stretches moved onto the trail.
    private static let atTheEnds = RouteAssembly(
        pieces: [.check(1), .kept(3...7), .check(2)],
        checks: [snapped(1, 0...3), snapped(2, 7...10)]
    )

    /// The walk a recording writes for itself, from Start to Stop.
    private func recordedWalk(of hike: Hike, in context: ModelContext) throws -> HikeWalk {
        let length = Self.savedDistances[10]
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: Clock.pressedStart,
            endedAt: Clock.pressedStop,
            activeSeconds: 10 * Line.secondsPerPoint,
            coveredIntervals: [0, length],
            furthestDistanceMeters: length,
            routeDistanceMeters: length,
            endReason: .recorded,
            routeRevision: TrailWalkRecord.routeRevision(of: Self.saved)
        )
        context.insert(walk)
        walk.hike = hike
        hike.date = Clock.pressedStart
        try context.save()
        return walk
    }

    // MARK: Answers given while the line is drawn

    @Test("two answers given before the line has caught up are both kept")
    func answersGivenTogetherAreBothKept() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context, assembly: Self.twoChecks)
        let session = await visit(hike, in: context)

        let first = Task { await session.choose(.gps, forCheck: 1) }
        let second = Task { await session.choose(.gps, forCheck: 2) }
        await first.value
        await second.value
        await session.settled()

        #expect(session.checks.map(\.choice) == [.gps, .gps])
        let line = try #require(session.line)
        #expect(line.choices == [1: .gps, 2: .gps])
        for id in [1, 2] {
            let stretch = try #require(line.checkRanges[id])
            #expect(line.route[stretch].allSatisfy { $0.longitude == Line.longitude + Line.traceOffset })
        }
    }

    @Test("an answer taken back before the line has caught up is the one the line ends under")
    func anAnswerTakenBackWins() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)

        let answering = Task { await session.choose(.gps, forCheck: Line.checkID) }
        await settleDelegateHop(until: "the answer to stand") { session.checks.first?.choice == .gps }
        await session.choose(.matched, forCheck: Line.checkID)
        await answering.value
        await session.settled()

        #expect(session.checks.first?.choice == .matched)
        #expect(session.line?.route == Self.saved)
        #expect(!session.hasChanges)
    }

    @Test("Save waits for the line to be drawn under the last answer, and keeps it")
    func saveWaitsForTheAnswer() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)

        let answering = Task { await session.choose(.gps, forCheck: Line.checkID) }
        await settleDelegateHop(until: "the answer to stand") { session.checks.first?.choice == .gps }
        let landed = await session.save(to: destination(for: hike, in: context))
        await answering.value

        #expect(landed)
        #expect(hike.routeEdit?.assembly?.checks.first?.choice == .gps)
        let line = try #require(session.line)
        #expect(line.choices == [Line.checkID: .gps])
        #expect(hike.route == line.route)
        let stretch = try #require(line.checkRanges[Line.checkID])
        #expect(hike.route[stretch].allSatisfy { $0.longitude == Line.longitude + Line.traceOffset })
    }

    // MARK: The cuts

    @Test("an answer changed and changed back puts a cut inside its section back where it was")
    func aCutComesBackWithItsAnswer() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let first = await visit(hike, in: context)
        let inside = (Self.savedDistances[4] + Self.savedDistances[5]) / 2
        first.move(.start, to: inside)
        #expect(await first.save(to: destination(for: hike, in: context)))
        let again = await visit(hike, in: context)
        #expect(again.startMeters == inside)

        await again.choose(.gps, forCheck: Line.checkID)
        let stretch = try #require(again.line?.meters(ofCheck: Line.checkID))
        #expect(again.startMeters == stretch.lowerBound, "inside a section drawn anew, the cut keeps it whole")
        await again.choose(.matched, forCheck: Line.checkID)

        #expect(again.startMeters == inside)
        #expect(!again.hasChanges, "nothing was moved by hand, so nothing is changed")

        // The other handle moved by hand on the way leaves this one's place.
        await again.choose(.gps, forCheck: Line.checkID)
        again.move(.end, to: again.totalMeters - 10)
        await again.choose(.matched, forCheck: Line.checkID)

        #expect(again.startMeters == inside)
        #expect(again.endMeters.isApproximatelyEqual(to: again.totalMeters - 10, absoluteTolerance: 0.001))
    }

    // MARK: The clock

    @Test("an answer at either end of the line leaves when the walk began and ended")
    func anAnswerAtAnEndKeepsTheClock() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context, assembly: Self.atTheEnds)
        let walk = try recordedWalk(of: hike, in: context)
        let session = await visit(hike, in: context)
        await session.choose(.gps, forCheck: 1)
        await session.choose(.gps, forCheck: 2)

        #expect(await session.save(to: destination(for: hike, in: context)))

        #expect(hike.route.first == Self.raw.first, "the line begins on the first fix now")
        #expect(hike.route.last == Self.raw.last)
        #expect(hike.date == Clock.pressedStart)
        #expect(walk.startedAt == Clock.pressedStart)
        #expect(walk.endedAt == Clock.pressedStop, "Stop was pressed after the last fix")
    }

    @Test("a cut taken back out gives the walk back the start and the end it had")
    func anUncutEndGetsItsClockBack() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let walk = try recordedWalk(of: hike, in: context)
        let first = await visit(hike, in: context)
        first.move(.start, to: Self.savedDistances[1])
        first.move(.end, to: Self.savedDistances[9])
        #expect(await first.save(to: destination(for: hike, in: context)))
        #expect(hike.date == Self.point(1).timestamp)
        #expect(walk.endedAt == Self.point(9).timestamp)

        let again = await visit(hike, in: context)
        // An answer changed too, so the save is an edit and not a revert.
        await again.choose(.gps, forCheck: Line.checkID)
        again.move(.start, to: 0)
        again.move(.end, to: again.totalMeters)
        #expect(again.trim == nil)
        #expect(await again.save(to: destination(for: hike, in: context)))

        #expect(hike.hasOriginalRoute)
        #expect(hike.date == Clock.pressedStart)
        #expect(walk.startedAt == Clock.pressedStart)
        #expect(walk.endedAt == Clock.pressedStop)
    }

    // MARK: The trace

    @Test("a section answered with fixes that have not come yet is not opened for editing")
    func aMissingTraceIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let first = await visit(hike, in: context)
        await first.choose(.gps, forCheck: Line.checkID)
        #expect(await first.save(to: destination(for: hike, in: context)))
        // What another device has of it before iCloud brings the asset.
        hike.rawRoute = []
        try context.save()

        let sources = await RouteEditSources.reading(hike, drawn: hike.route, in: context.container)
        let session = RouteTrimSession()
        await session.load(sources)

        #expect(sources.isMissingTrace)
        #expect(!sources.isMissingOriginal)
        #expect(session.line == nil, "a save would draw the section as it was saved, under the GPS answer")
        #expect(session.refusal == .notHereYet)
    }

    @Test("an answer drawn from a trace that has not come yet is not offered")
    func aMissingTraceOffersNoFixes() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        hike.rawRoute = []
        try context.save()

        let session = await visit(hike, in: context)

        let check = try #require(session.checks.first)
        #expect(session.line?.route == Self.saved, "the line as it was saved needs no trace")
        #expect(session.choices(of: check) == [.matched])
        #expect(session.choiceMeters[Line.checkID].map { Set($0.keys) } == [.matched])
        await session.choose(.gps, forCheck: Line.checkID)
        #expect(session.checks.first?.choice == .matched)
        #expect(!session.hasChanges)
    }

    // MARK: A drive and nothing else

    @Test("a drive off the end with nothing else to check is asked about, and Looks Good answers it")
    func aDriveAloneCanBeLookedAt() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.saved)
        let ends = try #require(RouteEdit.NotOnFoot(Self.carriedEnds))
        hike.routeEdit = RouteEdit(notOnFoot: ends)
        try context.save()

        let session = await visit(hike, in: context)

        #expect(session.isOwedALook)
        #expect(!session.hasChanges)
        #expect(await session.confirmChecks(in: destination(for: hike, in: context)))
        #expect(hike.routeEdit?.isOwedALook == false)
        #expect(hike.routeEdit?.notOnFoot?.trailingMeters == ends.trailingMeters, "a ride kept on purpose")
        #expect(hike.route == Self.saved)
        #expect(!hike.hasOriginalRoute)
    }

    @Test("an answer that draws the line again forgets where the junctions on the old one were")
    func anAnswerForgetsTheJunctions() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        session.junctionMeters = [Self.savedDistances[2], Self.savedDistances[8]]

        await session.choose(.gps, forCheck: Line.checkID)

        #expect(session.line?.choices[Line.checkID] == .gps, "precondition: the line is drawn again")
        #expect(session.junctionMeters.isEmpty, "they were measured along the line the old answer drew")
    }
}
