//
//  RouteTrimSessionTests+StoredCuts.swift
//  OpenHikesTests
//
//  A trim is kept with the hike as two cuts on the whole line, so *Edit
//  Route* opens on them again. That has to include the one cut no distance
//  can say: the pause standing on the line's own end, which a drive home with
//  the recording paused leaves there — see ``RouteTrim/EndPauses``.
//
//  And what the Save button is told of them, from before there is a line.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension RouteTrimSessionTests {
    private enum Drive {
        static let startSeconds: TimeInterval = 1_750_000_000
        static var start: Date { Date(timeIntervalSince1970: startSeconds) }
        static let latitude = 47.63
        static let longitude = 12.86
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        static let walkedPoints = 11
        /// About 14 km on, three hours later.
        static let drivenSteps = 140.0
        static let drivenSeconds: TimeInterval = 10_800
    }

    /// Eleven points north, then the first fix after the drive home, with
    /// the recording paused through it.
    private static let walkThenPausedDrive: [RouteCoordinate] = (0..<Drive.walkedPoints).map { index in
        RouteCoordinate(
            latitude: Drive.latitude + Double(index) * Drive.spacing,
            longitude: Drive.longitude,
            timestamp: Drive.start.addingTimeInterval(Double(index) * Drive.secondsPerPoint)
        )
    } + [
        RouteCoordinate(
            latitude: Drive.latitude + Drive.drivenSteps * Drive.spacing,
            longitude: Drive.longitude,
            timestamp: Drive.start.addingTimeInterval(Drive.drivenSeconds),
            boundary: .paused
        ),
    ]

    @Test("a pause taken off the line's end is kept with the hike, and found taken off on the next visit")
    func aPauseTakenOffIsStored() async throws {
        let context = try Fixture.modelContext()
        let whole = Self.walkThenPausedDrive
        let hike = Fixture.hike(in: context, route: whole)
        try context.save()
        let session = RouteTrimSession()
        await session.load(RouteEditSources.reading(hike, drawn: whole, in: context.container))
        let drive = try #require(session.line?.carriedEnds.trailing)
        session.takeOff(drive, at: .end)
        #expect(session.hasChanges)

        let landed = await session.save(
            to: RouteTrimSession.Destination(hike: hike, context: context) { whole }
        )

        #expect(landed)
        #expect(hike.route == Array(whole.dropLast()))
        #expect(hike.routeEdit?.endPausesTakenOff == .end)
        #expect(hike.routeEdit?.trim != nil, "a cut that takes a pause off is a trim, though it stands on the end")

        let again = RouteTrimSession()
        await again.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))
        let stillThere = try #require(again.line?.carriedEnds.trailing)

        #expect(again.pausesTakenOff == .end)
        #expect(again.hasTakenOff(stillThere, at: .end), "so the offer is not made a second time")
        #expect(!again.hasChanges)

        // Dragged off the end and back, the handle stands where it was put,
        // which leaves the pause: that is the whole line again, and a save
        // of it is the original.
        again.move(.end, to: again.totalMeters * 0.9)
        again.move(.end, to: again.totalMeters)
        #expect(again.trim == nil)
        #expect(again.hasChanges)
        await again.save(to: RouteTrimSession.Destination(hike: hike, context: context) { hike.route })

        #expect(hike.route == whole)
        #expect(!hike.hasOriginalRoute)
        #expect(hike.routeEdit?.endPausesTakenOff.isEmpty != false)
    }

    /// Where the boundary test cuts the walk, both exact in binary, so a
    /// handle moved half a meter is half a meter to the last bit.
    private enum StoredCut {
        static let start = 200.0
        static let end = 800.0
        /// Within ``RouteTrimSession/endToleranceMeters``, and past it.
        static let atTolerance = 0.5
        static let pastTolerance = 0.75
    }

    /// A cut put back within half a meter of where it was saved is where it
    /// was saved: a drag that lands a hair off a handle's own spot is no edit.
    /// Past that it is one, at either end.
    @Test("a stored cut moved up to half a meter is no change, and moved further at either end is one")
    func aStoredCutsTolerance() async throws {
        let context = try Fixture.modelContext()
        let walk = Array(Self.walkThenPausedDrive.prefix(Drive.walkedPoints))
        let hike = Fixture.hike(in: context, route: walk)
        try context.save()
        let first = RouteTrimSession()
        await first.load(RouteEditSources.reading(hike, drawn: walk, in: context.container))
        first.move(.start, to: StoredCut.start)
        first.move(.end, to: StoredCut.end)
        await first.save(to: RouteTrimSession.Destination(hike: hike, context: context) { walk })
        try #require(hike.routeEdit?.trim == StoredCut.start...StoredCut.end)

        let session = RouteTrimSession()
        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))
        #expect(!session.hasChanges)

        session.move(.start, to: StoredCut.start + StoredCut.atTolerance)
        session.move(.end, to: StoredCut.end - StoredCut.atTolerance)
        #expect(!session.hasChanges, "both cuts at the tolerance are where they were saved")

        session.move(.start, to: StoredCut.start + StoredCut.pastTolerance)
        #expect(session.hasChanges, "the start past it is a change")

        session.move(.start, to: StoredCut.start)
        session.move(.end, to: StoredCut.end - StoredCut.pastTolerance)
        #expect(session.hasChanges, "and so is the end")

        session.move(.end, to: StoredCut.end)
        #expect(!session.hasChanges)
    }

    /// `isApproximatelyEqual` calls two equal infinities equal; a cut that
    /// is not finite stands nowhere, and is never the cut that was saved.
    @Test("trims are the same within the tolerance, never with an end that is not finite, and none only as none")
    func trimSameness() {
        let saved = StoredCut.start...StoredCut.end
        let open = StoredCut.start...Double.infinity

        #expect(RouteTrimSession.isSame(saved, (StoredCut.start - StoredCut.atTolerance)...StoredCut.end))
        #expect(!RouteTrimSession.isSame(saved, StoredCut.start...(StoredCut.end + StoredCut.pastTolerance)))
        #expect(!RouteTrimSession.isSame(open, open))
        #expect(!RouteTrimSession.isSame(saved, open))
        #expect(RouteTrimSession.isSame(nil, nil))
        #expect(!RouteTrimSession.isSame(saved, nil))
    }

    /// The Save button is drawn before the line has loaded, and Observation
    /// tells a view only of what it read. An answer given before anything
    /// was read left the button disabled for good: found by the UI suite,
    /// where a cut moved and Save never woke.
    @Test("a Save button drawn before the line has loaded hears of the load, and of a cut moved after it")
    func theSaveButtonHearsOfTheLine() async {
        let session = RouteTrimSession()
        let button = ObservationCounter { _ = session.hasChanges }
        await button.settle()
        #expect(!session.hasChanges)

        await session.load(Self.walkThenPausedDrive)
        await button.settle()
        #expect(button.count == 1, "the line arriving is news to whoever asked before it had")

        session.move(.end, to: session.totalMeters / 2)
        await button.settle()
        #expect(button.count == 2)
        #expect(session.hasChanges)
    }
}
