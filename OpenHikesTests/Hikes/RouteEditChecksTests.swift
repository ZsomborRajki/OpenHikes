//
//  RouteEditChecksTests.swift
//  OpenHikesTests
//
//  *Edit Route* on a recording that was saved with stretches to check, and on
//  a hike that has been trimmed before: the visit opens on the whole line,
//  an answer changed puts the line together again with the cuts on the
//  ground they stood on, and a save keeps the answers, the cuts and the look
//  with the hike.
//
//  What is defended is that an answer is never destructive. The line as it
//  was saved and the recorded trace are what every answer is drawn from, so
//  changing one and changing it back, on any device and after any trim, gives
//  the line there was.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Route edit checks")
struct RouteEditChecksTests {
    enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        /// A thousandth of a degree of latitude between points, about 111 m.
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        /// How far east of the trail the fixes were recorded: about 7.5 m.
        static let traceOffset = 0.0001
        static let checkID = 1
        /// The points of the stretch to check, in the saved line and the
        /// trace alike.
        static let stretch = 3...6
    }

    static func point(_ index: Int, east: Double = 0) -> RouteCoordinate {
        RouteCoordinate(
            latitude: Line.latitude + Double(index) * Line.spacing,
            longitude: Line.longitude + east,
            timestamp: Line.start.addingTimeInterval(Double(index) * Line.secondsPerPoint)
        )
    }

    /// The line Stop saved: eleven points north along the trail.
    static let saved = (0...10).map { point($0) }
    /// The fixes it was recorded as, beside the trail.
    static let raw = (0...10).map { point($0, east: Line.traceOffset) }
    static let savedDistances = RouteTrim.distances(along: saved)

    /// The middle of the line was moved onto a trail; the ends were left.
    static let assembly = RouteAssembly(
        pieces: [.kept(0...Line.stretch.lowerBound), .check(Line.checkID), .kept(Line.stretch.upperBound...10)],
        checks: [
            RouteCheck(
                id: Line.checkID,
                kind: .snapped,
                savedChoice: .matched,
                savedRange: Line.stretch,
                rawRange: Line.stretch,
                trailName: "Ridge Path"
            ),
        ]
    )

    /// A recording as Stop saves it: its line, its trace and its question.
    func recording(
        in context: ModelContext,
        notOnFoot: RouteEdit.NotOnFoot? = nil,
        assembly: RouteAssembly = Self.assembly
    ) throws -> Hike {
        let hike = Fixture.hike(in: context, route: Self.saved)
        hike.rawRoute = Self.raw
        hike.routeEdit = RouteEdit(assembly: assembly, notOnFoot: notOnFoot)
        try context.save()
        return hike
    }

    func visit(_ hike: Hike, in context: ModelContext) async -> RouteTrimSession {
        let session = RouteTrimSession()
        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))
        return session
    }

    func destination(for hike: Hike, in context: ModelContext) -> RouteTrimSession.Destination {
        RouteTrimSession.Destination(hike: hike, context: context) { hike.route }
    }

    /// *Looks Good*, tapped on what the visit shows now, or on `shown`.
    func look(
        _ session: RouteTrimSession,
        at hike: Hike,
        in context: ModelContext,
        tappedOn shown: Int? = nil
    ) async -> Bool {
        await session.confirmChecks(in: destination(for: hike, in: context), tappedOn: shown ?? session.sourcesRevision)
    }

    // MARK: Opening

    @Test("a recording with a stretch to check opens whole, with nothing changed")
    func openingOnAStretchToCheck() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)

        let session = await visit(hike, in: context)

        #expect(session.checks.count == 1)
        #expect(session.isOwedALook)
        #expect(!session.hasChanges)
        #expect(session.trim == nil)
        #expect(!session.drawsKeptLine, "the hike's own line on the map is the kept one")
        let line = try #require(session.line)
        #expect(line.route == Self.saved)
        #expect(line.checkRanges[Line.checkID] == Line.stretch)
        #expect(line.coordinates(ofCheck: Line.checkID).count == Line.stretch.count)
        let lengths = try #require(session.choiceMeters[Line.checkID])
        #expect(Set(lengths.keys) == [.matched, .gps])
        #expect(await session.editedLine() == nil, "nothing is changed, so there is nothing to save")
    }

    @Test("a hike with no edit and no question is read as its line alone")
    func aPlainHikeHasOnlyItsLine() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.saved)
        try context.save()

        let sources = await RouteEditSources.reading(hike, drawn: Self.saved, in: context.container)

        #expect(sources == RouteEditSources(current: Self.saved))
        #expect(sources.whole.route == Self.saved)
        #expect(!sources.isMissingOriginal)
    }

    // MARK: Answering

    @Test("an answer changed puts the line together again, and each cut stays on its ground")
    func anAnswerMovesTheLineAndKeepsTheCuts() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        let before = session.totalMeters
        session.move(.start, to: Self.savedDistances[1])
        session.move(.end, to: Self.savedDistances[8])
        let revision = session.lineRevision

        await session.choose(.gps, forCheck: Line.checkID)

        #expect(session.lineRevision == revision + 1)
        #expect(session.checks.first?.choice == .gps)
        #expect(session.focusedCheckID == Line.checkID)
        let gained = session.totalMeters - before
        #expect(gained > 10, "the trace leaves the trail and comes back: two steps of about 7.5 m")
        #expect(session.startMeters == Self.savedDistances[1], "before the stretch, nothing moved")
        #expect(session.endMeters.isApproximatelyEqual(to: Self.savedDistances[8] + gained, absoluteTolerance: 0.001))
        #expect(session.hasChanges)
        #expect(session.drawsKeptLine)
        #expect(session.staleStretches.map(\.count) == [Line.stretch.count])
        let line = try #require(session.line)
        #expect(line.route.count == Self.saved.count + 2, "the stretch's ends are no longer shared points")
        let stretch = try #require(line.checkRanges[Line.checkID])
        #expect(line.route[stretch].allSatisfy { $0.longitude == Line.longitude + Line.traceOffset })

        await session.choose(.matched, forCheck: Line.checkID)

        #expect(session.line?.route == Self.saved, "and back again is the line there was")
        #expect(session.endMeters.isApproximatelyEqual(to: Self.savedDistances[8], absoluteTolerance: 0.001))
        #expect(session.staleStretches.isEmpty)
    }

    @Test("a cut inside a stretch that changes goes to the side that keeps the stretch whole")
    func aCutInsideTheStretchLeavesIt() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        let before = try #require(session.line)
        await session.choose(.gps, forCheck: Line.checkID)
        let after = try #require(session.line)
        let old = try #require(before.meters(ofCheck: Line.checkID))
        let new = try #require(after.meters(ofCheck: Line.checkID))
        let inside = (old.lowerBound + old.upperBound) / 2

        #expect(before.meters(matching: inside, on: after, for: .start) == new.lowerBound)
        #expect(before.meters(matching: inside, on: after, for: .end) == new.upperBound)
        #expect(before.meters(matching: before.totalMeters, on: after, for: .end) == after.totalMeters)
        #expect(before.meters(matching: 0, on: after, for: .start) == 0)
        // Past the stretch and the legs joining it, by all the line gained.
        let beyond = Self.savedDistances[8]
        #expect(before.meters(matching: beyond, on: after, for: .end).isApproximatelyEqual(
            to: beyond + after.totalMeters - before.totalMeters,
            absoluteTolerance: 0.001
        ))
    }

    @Test("the answer a stretch has, and one it does not offer, change nothing")
    func answersThatAreNoChange() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        let revision = session.lineRevision

        await session.choose(.matched, forCheck: Line.checkID)
        await session.choose(.alternative(0), forCheck: Line.checkID)
        await session.choose(.gps, forCheck: 99)

        #expect(session.lineRevision == revision)
        #expect(!session.hasChanges)
    }

    // MARK: Saving

    @Test("a save keeps the answer, the look and the line it was saved from")
    func savingAnAnswer() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        await session.choose(.gps, forCheck: Line.checkID)
        let chosen = try #require(session.line?.route)

        let landed = await session.save(to: destination(for: hike, in: context))

        #expect(landed)
        #expect(hike.route == chosen)
        #expect(hike.originalRoute == Self.saved)
        #expect(hike.rawRoute == Self.raw, "the trace is what every answer is drawn from, and is never cut")
        let edit = try #require(hike.routeEdit)
        #expect(edit.trim == nil)
        #expect(edit.assembly?.checks.first?.choice == .gps)
        #expect(edit.assembly?.checks.first?.isChecked == true)
        #expect(!edit.isOwedALook)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: chosen.lengthMeters, absoluteTolerance: 0.01))
    }

    @Test("a hike trimmed before opens on its whole line, and a cut can be taken back out")
    func aTrimIsTwoCutsOnTheWholeLine() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let first = await visit(hike, in: context)
        first.move(.end, to: Self.savedDistances[6])
        await first.save(to: destination(for: hike, in: context))
        #expect(hike.route == Array(Self.saved[0...6]))
        #expect(hike.routeEdit?.trim == 0...Self.savedDistances[6])

        let again = await visit(hike, in: context)

        #expect(again.totalMeters.isApproximatelyEqual(to: Self.savedDistances[10], absoluteTolerance: 0.001))
        #expect(again.endMeters == Self.savedDistances[6])
        #expect(again.drawsKeptLine, "a handle can be dragged where the hike's own line no longer is")
        #expect(!again.hasChanges)

        again.move(.end, to: Self.savedDistances[8])
        await again.save(to: destination(for: hike, in: context))

        #expect(hike.route == Array(Self.saved[0...8]))
        #expect(hike.originalRoute == Self.saved)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: Self.savedDistances[8], absoluteTolerance: 0.01))
        #expect(hike.routeEdit?.trim == 0...Self.savedDistances[8])
    }

    @Test("every cut taken back out, with every answer as saved, is the original again")
    func undoingEverythingIsARevert() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let distance = hike.distanceMeters
        let first = await visit(hike, in: context)
        first.move(.end, to: Self.savedDistances[6])
        await first.save(to: destination(for: hike, in: context))
        let again = await visit(hike, in: context)

        again.move(.end, to: again.totalMeters)
        #expect(again.trim == nil)
        #expect(again.hasChanges)
        let landed = await again.save(to: destination(for: hike, in: context))

        #expect(landed)
        #expect(hike.route == Self.saved)
        #expect(!hike.hasOriginalRoute)
        #expect(hike.originalRoute.isEmpty)
        #expect(hike.distanceMeters == distance, "the figure it had, not one worked back to")
        #expect(hike.routeEdit?.trim == nil)
        #expect(hike.routeEdit?.assembly?.isAsSaved == true)
    }

    @Test("a revert puts every stretch back the way it was saved, and does not ask again")
    func revertingAnAnswer() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let session = await visit(hike, in: context)
        await session.choose(.gps, forCheck: Line.checkID)
        await session.save(to: destination(for: hike, in: context))

        #expect(await session.revert(in: destination(for: hike, in: context)))

        #expect(hike.route == Self.saved)
        let check = try #require(hike.routeEdit?.assembly?.checks.first)
        #expect(check.choice == .matched)
        #expect(check.isChecked, "the hiker has answered for it once")
        #expect(hike.routeEdit?.isOwedALook == false)
    }

    @Test("an edited hike whose original has not arrived is not opened for editing")
    func anEditWithoutItsOriginalIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let first = await visit(hike, in: context)
        first.move(.end, to: Self.savedDistances[6])
        await first.save(to: destination(for: hike, in: context))
        // What another device has of it before iCloud brings the asset.
        hike.originalRoute = []
        try context.save()

        let sources = await RouteEditSources.reading(hike, drawn: hike.route, in: context.container)
        let session = RouteTrimSession()
        await session.load(sources)

        #expect(sources.isMissingOriginal)
        #expect(session.line == nil)
        #expect(session.refusal == .notHereYet)
        #expect(RouteEditRefusal.notHereYet.errorDescription == "This route can’t be edited yet.")
        #expect(RouteEditRefusal.notHereYet.recoverySuggestion == RouteEditRefusal.noOriginal.recoverySuggestion)
    }

    // MARK: Looking

    @Test("Looks Good keeps the line and stops the hike asking")
    func confirmingChangesNothingButTheLook() async throws {
        let context = try Fixture.modelContext()
        let ends = try #require(RouteEdit.NotOnFoot(Self.carriedEnds))
        let hike = try recording(in: context, notOnFoot: ends)
        #expect(RouteCheckWording.noticeLines(for: try #require(hike.routeEdit)).count == 2)
        let session = await visit(hike, in: context)
        let revision = session.lineRevision

        #expect(await look(session, at: hike, in: context))

        #expect(hike.route == Self.saved)
        #expect(hike.originalRoute.isEmpty)
        let edit = try #require(hike.routeEdit)
        #expect(edit.uncheckedCount == 0)
        #expect(edit.uncheckedNotOnFoot == nil)
        #expect(edit.notOnFoot?.trailingMeters == ends.trailingMeters, "it is still a fact about the line")
        #expect(!edit.isOwedALook)
        #expect(RouteCheckWording.noticeLines(for: edit).isEmpty)
        #expect(!session.isOwedALook)
        #expect(session.checks.first?.isChecked == true)

        // The screen loads again when the hike's edit record moves, and finds
        // what it already has.
        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))
        #expect(session.lineRevision == revision)
    }

    @Test("a look the store refuses to keep is not kept")
    func aRefusedLookIsPutBack() throws {
        struct Refused: Error {}
        let context = try Fixture.modelContext()
        let hike = try recording(in: context)
        let before = hike.routeEditData

        let edit = RouteEditSave.markChecked(hike, in: context) { _ in throw Refused() }

        #expect(edit == nil)
        #expect(hike.routeEditData == before)
        #expect(hike.routeEdit?.isOwedALook == true)
    }

    /// A drive off the end of a walk, as ``RouteCarriedEnds`` reports one.
    static let carriedEnds = RouteCarriedEnds(
        trailing: RouteCarriedEnds.Stretch(range: 1000...9000, carriedMeters: 8000)
    )
}
