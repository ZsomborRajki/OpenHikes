//
//  RouteEditSaveTests.swift
//  OpenHikesTests
//
//  *Edit Route* on a hike that was recorded or imported: a trim writes the
//  kept line into the same hike and keeps the one it had, *Revert to
//  Original* puts all of it back, and a save the store refuses leaves the
//  hike exactly as it was.
//
//  What is defended is that an edit is never the only copy of a walk, and
//  that the figures about the line move with it: the hike's distance, the
//  recording's own walk, and what was measured along the old line.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Route edit save")
struct RouteEditSaveTests {
    private enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        /// A thousandth of a degree of latitude between points, about 111 m.
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        static let pointCount = 11
        static let baseElevation: Double = 600
        static let climbPerPoint: Double = 5
    }

    /// Eleven points north along a meridian, a minute apart.
    private static let route: [RouteCoordinate] = (0..<Line.pointCount).map { index in
        RouteCoordinate(
            latitude: Line.latitude + Double(index) * Line.spacing,
            longitude: Line.longitude,
            elevation: Line.baseElevation + Double(index) * Line.climbPerPoint,
            timestamp: Line.start.addingTimeInterval(Double(index) * Line.secondsPerPoint)
        )
    }

    private static let distances = RouteTrim.distances(along: route)
    private static let length = distances[Line.pointCount - 1]

    /// The route cut to the points `range` names.
    private static func edited(keeping range: ClosedRange<Int>) throws -> EditedLine {
        try #require(EditedLine(
            trimming: route,
            distances: distances,
            to: distances[range.lowerBound]...distances[range.upperBound]
        ))
    }

    /// A recorded hike: the route, and the walk a recording writes for itself.
    private func recording(in context: ModelContext) throws -> (hike: Hike, walk: HikeWalk) {
        let hike = Fixture.hike(in: context, route: Self.route)
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: Line.start.addingTimeInterval(-5),
            endedAt: Line.start.addingTimeInterval(700),
            activeSeconds: 600,
            coveredIntervals: [0, Self.length],
            furthestDistanceMeters: Self.length,
            routeDistanceMeters: Self.length,
            endReason: .recorded,
            routeRevision: TrailWalkRecord.routeRevision(of: Self.route)
        )
        context.insert(walk)
        walk.hike = hike
        try context.save()
        return (hike, walk)
    }

    private struct Refused: Error {}

    // MARK: A trim

    @Test("a trim writes the kept line and keeps the one it had")
    func aTrimKeepsTheOriginal() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let date = hike.date

        let outcome = RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...6), in: context)

        #expect(outcome == .saved(Array(Self.route[0...6])))
        #expect(hike.route == Array(Self.route[0...6]))
        #expect(hike.originalRoute == Self.route)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: Self.distances[6], absoluteTolerance: 0.01))
        #expect(hike.durationSeconds == 360)
        #expect(hike.date == date, "an end cut off does not move when the hike began")
        let original = try #require(hike.routeEdit?.original)
        #expect(original.distanceMeters.isApproximatelyEqual(to: Self.length, absoluteTolerance: 0.01))
        #expect(hike.hasOriginalRoute)
    }

    @Test("a second trim leaves the first original alone")
    func aSecondTrimKeepsTheFirstOriginal() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...8), in: context)
        let once = hike.route
        let again = try #require(EditedLine(
            trimming: once,
            distances: RouteTrim.distances(along: once),
            to: Self.distances[2]...Self.distances[8]
        ))

        RouteEditSave.trim(hike, from: once, to: again, in: context)

        #expect(hike.route == Array(Self.route[2...8]))
        #expect(hike.originalRoute == Self.route)
        let original = try #require(hike.routeEdit?.original)
        #expect(original.distanceMeters.isApproximatelyEqual(to: Self.length, absoluteTolerance: 0.01))
    }

    @Test("a recording's distance loses what was cut, not what it stood still for")
    func aRecordingsDistanceLosesTheCut() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        // Shorter than its line, as a recording's is: see `PreparedRecording`.
        hike.distanceMeters = Self.length - 40

        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...6), in: context)

        #expect(hike.distanceMeters.isApproximatelyEqual(to: Self.distances[6] - 40, absoluteTolerance: 0.01))
    }

    @Test("a trimmed start moves when the hike began")
    func aTrimmedStartMovesTheDate() throws {
        let context = try Fixture.modelContext()
        let (hike, walk) = try recording(in: context)
        let ended = walk.endedAt

        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 2...10), in: context)

        let began = Line.start.addingTimeInterval(2 * Line.secondsPerPoint)
        #expect(hike.date == began)
        #expect(walk.startedAt == began)
        #expect(walk.endedAt == ended, "the end was not cut, so Stop is still when it ended")
    }

    @Test("the recording's own walk is cut with its line, and other walks are not")
    func theRecordedWalkIsCutWithIt() throws {
        let context = try Fixture.modelContext()
        let (hike, walk) = try recording(in: context)
        let started = walk.startedAt
        let follow = HikeWalk(
            hikeID: hike.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 900,
            coveredIntervals: [0, 300],
            furthestDistanceMeters: 300,
            routeDistanceMeters: Self.length,
            endReason: .ended,
            routeRevision: TrailWalkRecord.routeRevision(of: Self.route)
        )
        context.insert(follow)
        follow.hike = hike
        try context.save()

        let edited = try Self.edited(keeping: 0...6)
        RouteEditSave.trim(hike, from: Self.route, to: edited, in: context)

        #expect(walk.startedAt == started)
        #expect(walk.endedAt == Line.start.addingTimeInterval(6 * Line.secondsPerPoint))
        #expect(walk.activeSeconds == 360, "four minutes of the ten were on the stretch cut off")
        #expect(walk.coveredIntervals == [0, edited.lengthMeters])
        #expect(walk.routeDistanceMeters == edited.lengthMeters)
        #expect(walk.isAlong(revision: TrailWalkRecord.routeRevision(of: hike.route)))
        #expect(follow.activeSeconds == 900)
        #expect(follow.routeDistanceMeters == Self.length)
        #expect(!follow.isAlong(revision: TrailWalkRecord.routeRevision(of: hike.route)))
    }

    @Test("what was measured along the old line is cleared")
    func whatDescribedTheOldLineIsCleared() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route) { hike in
            hike.surfaceMetersByCategory = ["paved": 400]
            hike.difficultyMetersByGrade = ["hiking": 400]
            hike.climbMeters = 50
            hike.descentMeters = 0
            hike.elevationRouteRevision = "the-old-line"
        }

        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...6), in: context)

        #expect(hike.surfaceMetersByCategory.isEmpty)
        #expect(hike.difficultyMetersByGrade.isEmpty)
        #expect(hike.climbMeters == nil)
        #expect(hike.descentMeters == nil)
        #expect(hike.elevationRouteRevision == nil)
    }

    @Test("cuts that leave no line make no edit")
    func noLineNoEdit() {
        #expect(EditedLine(trimming: Self.route, distances: Self.distances, to: 100...100) == nil)
        #expect(EditedLine(trimming: [], distances: [], to: 0...100) == nil)
    }

    // MARK: Reverting

    @Test("reverting puts the line and its figures back, and keeps no original")
    func revertPutsEverythingBack() throws {
        let context = try Fixture.modelContext()
        let (hike, walk) = try recording(in: context)
        hike.distanceMeters = Self.length - 40
        let date = hike.date
        let recorded = RouteEdit.RecordedWalk(walk)
        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 2...6), in: context)

        let outcome = RouteEditSave.revert(hike, from: hike.route, in: context)

        #expect(outcome == .saved(Self.route))
        #expect(hike.route == Self.route)
        #expect(hike.originalRoute.isEmpty)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: Self.length - 40, absoluteTolerance: 0.01))
        #expect(hike.date == date)
        #expect(RouteEdit.RecordedWalk(walk) == recorded)
        #expect(hike.routeEditData == nil, "a hike never shared has nothing left to remember")
        #expect(!hike.hasOriginalRoute)
    }

    @Test("a hike with no original has nothing to revert to")
    func nothingToRevertTo() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)

        #expect(RouteEditSave.revert(hike, from: Self.route, in: context) == .refused(.noOriginal))
        #expect(hike.route == Self.route)
    }

    // MARK: A shared hike

    @Test("a shared hike learns its copy is out of date, from an edit and from a revert")
    func aSharedCopyGoesOutOfDate() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        hike.communitySubmissionID = "submission-1"
        #expect(!hike.isSharedCopyOutOfDate)

        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...6), in: context)
        #expect(hike.isSharedCopyOutOfDate)

        hike.communitySubmissionID = "submission-2"
        #expect(!hike.isSharedCopyOutOfDate, "a fresh share is the edited route")

        RouteEditSave.revert(hike, from: hike.route, in: context)
        #expect(hike.isSharedCopyOutOfDate, "the copy shows the cut line, and the hike its original again")
        #expect(!hike.hasOriginalRoute)
    }

    // MARK: A refused save

    @Test("a refused trim leaves the hike exactly as it was")
    func aRefusedTrimChangesNothing() throws {
        let context = try Fixture.modelContext()
        let (hike, walk) = try recording(in: context)
        hike.climbMeters = 50
        hike.surfaceMetersByCategory = ["paved": 400]
        try context.save()
        let distance = hike.distanceMeters
        let date = hike.date
        let recorded = RouteEdit.RecordedWalk(walk)

        let outcome = RouteEditSave.trim(
            hike,
            from: Self.route,
            to: try Self.edited(keeping: 2...6),
            in: context
        ) { _ in throw Refused() }

        #expect(outcome == .refused(.notSaved))
        #expect(hike.route == Self.route)
        #expect(hike.originalRoute.isEmpty)
        #expect(hike.routeEditData == nil)
        #expect(hike.distanceMeters == distance)
        #expect(hike.date == date)
        #expect(hike.climbMeters == 50)
        #expect(hike.surfaceMetersByCategory == ["paved": 400])
        #expect(RouteEdit.RecordedWalk(walk) == recorded)
    }

    @Test("a refused revert leaves the edit exactly as it was")
    func aRefusedRevertChangesNothing() throws {
        let context = try Fixture.modelContext()
        let (hike, walk) = try recording(in: context)
        RouteEditSave.trim(hike, from: Self.route, to: try Self.edited(keeping: 0...6), in: context)
        let trimmed = hike.route
        let distance = hike.distanceMeters
        let edit = hike.routeEditData
        let recorded = RouteEdit.RecordedWalk(walk)

        let outcome = RouteEditSave.revert(hike, from: trimmed, in: context) { _ in throw Refused() }

        #expect(outcome == .refused(.notSaved))
        #expect(hike.route == trimmed)
        #expect(hike.originalRoute == Self.route)
        #expect(hike.routeEditData == edit)
        #expect(hike.distanceMeters == distance)
        #expect(RouteEdit.RecordedWalk(walk) == recorded)
    }
}
