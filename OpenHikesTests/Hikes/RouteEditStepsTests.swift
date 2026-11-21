//
//  RouteEditStepsTests.swift
//  OpenHikesTests
//
//  *Edit Route* beyond the two cuts: a stretch picked out with the handles
//  and straightened, taken out or drawn along mapped trails, a pull through
//  a spot on the map, and the whole line turned round, closed or doubled
//  back — each a step, kept with the hike in the order it was made.
//
//  What is defended is that a step is made on the line the hiker sees, that
//  it can be taken back, here and on the next visit, and that the cuts a
//  step was made on come back as cuts when it is.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Route edit steps")
struct RouteEditStepsTests {
    nonisolated enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        /// A thousandth of a degree of latitude between points, about 111 m.
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        /// How far east of the line the router's way round goes.
        static let detourOffset = 0.002
        static let walkSeconds: TimeInterval = 600
    }

    static func point(_ index: Int) -> RouteCoordinate {
        RouteCoordinate(
            latitude: Line.latitude + Double(index) * Line.spacing,
            longitude: Line.longitude,
            timestamp: Line.start.addingTimeInterval(Double(index) * Line.secondsPerPoint)
        )
    }

    /// Eleven points north along a meridian, a minute apart.
    static let route = (0...10).map { point($0) }
    static let distances = RouteTrim.distances(along: route)

    /// A router that knows one way between any two points: out to the east
    /// and back.
    nonisolated struct DetourRouter: TrailLegRouting {
        var snap: TrailLegSnap = .snapped
        var pointCount = 1

        @concurrent
        func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
            let rise = ends.end.latitude - ends.start.latitude
            let latitudes = (1...pointCount).map { step in
                ends.start.latitude + rise * Double(step) / Double(pointCount + 1)
            }
            let round = latitudes.map { RouteCoordinate(latitude: $0, longitude: Line.longitude + Line.detourOffset) }
            return TrailLegRoute(coordinates: [ends.start] + round + [ends.end], distanceMeters: 0, snap: snap)
        }
    }

    func visit(
        _ hike: Hike,
        in context: ModelContext,
        router: (any TrailLegRouting)? = nil
    ) async -> RouteTrimSession {
        let session = RouteTrimSession()
        session.routing = RouteReroute.Services(router: router)
        await session.load(RouteEditSources.reading(hike, drawn: hike.route, in: context.container))
        return session
    }

    func destination(for hike: Hike, in context: ModelContext) -> RouteTrimSession.Destination {
        RouteTrimSession.Destination(hike: hike, context: context) { hike.route }
    }

    func savedHike(in context: ModelContext) throws -> Hike {
        let saved = Fixture.hike(in: context, route: Self.route)
        try context.save()
        return saved
    }

    // MARK: A stretch

    @Test("a stretch picked out and straightened is a step, kept with the hike and found on the next visit")
    func aStretchStraightened() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)

        await session.beginStretch()
        #expect(session.isSelectingStretch)
        #expect(session.startMeters.isApproximatelyEqual(to: session.totalMeters / 3, absoluteTolerance: 0.01))
        #expect(session.endMeters.isApproximatelyEqual(to: session.totalMeters * 2 / 3, absoluteTolerance: 0.01))
        #expect(!session.hasChanges, "picking a stretch out changes nothing yet")
        #expect(session.trim == nil, "and the handles cut nothing while they pick")
        #expect(await session.editedLine() == nil)

        session.move(.start, to: Self.distances[3])
        session.move(.end, to: Self.distances[6])
        await session.straightenStretch()

        let step = RouteStep.replace(Self.distances[3]...Self.distances[6], with: .straight)
        #expect(!session.isSelectingStretch)
        #expect(session.steps == [step])
        #expect(session.line?.route == RouteSteps.applying(step, to: Self.route))
        #expect(session.startMeters == 0)
        #expect(session.endMeters == session.totalMeters)
        #expect(session.hasChanges)
        #expect(session.drawsKeptLine)
        #expect(session.staleStretches.map(\.count) == [4], "the ground the line no longer goes over is covered")

        #expect(await session.save(to: destination(for: hike, in: context)))

        #expect(hike.route == RouteSteps.applying(step, to: Self.route))
        #expect(hike.originalRoute == Self.route)
        #expect(hike.routeEdit?.routeSteps == [step])
        #expect(hike.routeEdit?.trim == nil)
        let again = await visit(hike, in: context)
        #expect(again.steps == [step])
        #expect(!again.hasChanges)
        #expect(!again.drawsKeptLine, "the hike's own line is the one the steps leave")
        #expect(again.canUndo)
    }

    @Test("a stretch taken out is a pause, and its time comes off the recording's own walk")
    func aStretchTakenOut() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: Line.start,
            endedAt: Line.start.addingTimeInterval(Line.walkSeconds),
            activeSeconds: Line.walkSeconds,
            coveredIntervals: [0, Self.distances[10]],
            furthestDistanceMeters: Self.distances[10],
            routeDistanceMeters: Self.distances[10],
            endReason: .recorded,
            routeRevision: TrailWalkRecord.routeRevision(of: Self.route)
        )
        context.insert(walk)
        walk.hike = hike
        try context.save()
        let session = await visit(hike, in: context)

        await session.beginStretch()
        session.move(.start, to: Self.distances[3])
        session.move(.end, to: Self.distances[6])
        await session.takeOutStretch()
        #expect(await session.save(to: destination(for: hike, in: context)))

        #expect(hike.route.count == 4 + 5)
        #expect(hike.route[4].isPauseBoundary)
        let kept = Self.distances[10] - 3 * Self.distances[1]
        #expect(hike.distanceMeters.isApproximatelyEqual(to: kept, absoluteTolerance: 0.1))
        #expect(walk.activeSeconds == Line.walkSeconds - 3 * Line.secondsPerPoint)
        #expect(walk.startedAt == Line.start, "neither end of the walk moved")
        #expect(walk.endedAt == Line.start.addingTimeInterval(Line.walkSeconds))
    }

    @Test("Follow Trails draws the stretch along the way the router finds, and says when it finds none")
    func followingTrails() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context, router: DetourRouter())
        await session.beginStretch()
        session.move(.start, to: Self.distances[3])
        session.move(.end, to: Self.distances[6])

        await session.followTrailsAcrossStretch()

        #expect(!session.isRouting)
        #expect(!session.isSelectingStretch)
        let drawn = try #require(session.line?.route)
        let east = Line.longitude + Line.detourOffset
        #expect(drawn.count == 4 + 1 + 5)
        #expect(drawn[4].longitude.isApproximatelyEqual(to: east, absoluteTolerance: 1e-6))
        #expect(drawn[4].isInferred)
        #expect(drawn[4].timestamp == nil)
        #expect(drawn[5].isInferred, "the leg back onto the line is the last of the guess")
        #expect(drawn[5].timestamp == Self.route[6].timestamp)

        let unmapped = await visit(hike, in: context, router: DetourRouter(snap: .unmapped(.noPathBetween)))
        await unmapped.beginStretch()
        await unmapped.followTrailsAcrossStretch()
        #expect(unmapped.refusal == .noMappedWay)
        #expect(unmapped.isSelectingStretch, "the stretch is still picked out, to straighten instead")
        #expect(unmapped.steps.isEmpty)

        let alone = await visit(hike, in: context)
        await alone.beginStretch()
        await alone.followTrailsAcrossStretch()
        #expect(alone.refusal == .noMappedWay)
    }

    @Test("a way round with more points than a hike's record keeps is refused")
    func aPathTooLongToKeep() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let router = DetourRouter(pointCount: RouteSteps.maximumPathCoordinates + 1)
        let session = await visit(hike, in: context, router: router)
        await session.beginStretch()

        await session.followTrailsAcrossStretch()

        #expect(session.refusal == .tooMuchToKeep)
        #expect(session.steps.isEmpty)
        #expect(session.line?.route == Self.route)
    }

    // MARK: The cuts

    @Test("cuts placed before a step are a step of their own, and Undo gives them back as cuts")
    func cutsBecomeAStep() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        session.move(.end, to: Self.distances[8])

        await session.reverse()

        #expect(session.steps == [.trim(0...Self.distances[8], endPauses: 0), .reverse])
        #expect(session.trim == nil, "the handles are on the ends of what the cut left")
        #expect(session.totalMeters.isApproximatelyEqual(to: Self.distances[8], absoluteTolerance: 0.01))
        #expect(session.line?.route.first?.latitude == Self.route[8].latitude)
        #expect(session.line?.route.allSatisfy { $0.timestamp == nil } == true)

        await session.undo()

        #expect(session.steps.isEmpty)
        #expect(session.line?.route == Self.route)
        #expect(session.endMeters == Self.distances[8])
        #expect(session.trim == 0...Self.distances[8])
        #expect(session.hasChanges, "the cut is still to save")
        #expect(!session.canUndo)
    }

    @Test("a stretch left alone gives the handles back to the cuts they were")
    func leavingAStretchAlone() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        session.move(.start, to: Self.distances[2])

        await session.beginStretch()
        #expect(session.steps == [.trim(Self.distances[2]...Self.distances[10], endPauses: 0)])
        #expect(session.totalMeters.isApproximatelyEqual(to: Self.distances[8], absoluteTolerance: 0.01))
        #expect(!session.hasChanges)
        #expect(!session.canUndo, "there is nothing to take back but the picking")

        await session.endStretch()

        #expect(!session.isSelectingStretch)
        #expect(session.steps.isEmpty)
        #expect(session.startMeters == Self.distances[2])
        #expect(session.hasChanges)

        await session.beginStretch()
        await session.endStretch()
        await session.beginStretch()
        await session.straightenStretch()
        #expect(session.steps.count == 2, "the cut is a step for good once one is made on it")
    }

    // MARK: A pull

    @Test("a pull is bounded by the junctions either side, and by the map's reach where none is known")
    func whereAPullStops() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        let pulled = Self.distances[5]

        #expect(session.pullBounds(around: pulled, reach: 150) == (pulled - 150)...(pulled + 150))

        session.junctionMeters = [Self.distances[1], Self.distances[4], Self.distances[7]]
        #expect(session.pullBounds(around: pulled, reach: 150) == Self.distances[4]...Self.distances[7])

        session.move(.end, to: Self.distances[6])
        #expect(
            session.pullBounds(around: pulled, reach: 150) == Self.distances[4]...Self.distances[6],
            "a pull redraws nothing a cut has taken off"
        )
        #expect(session.pullBounds(around: Self.distances[8], reach: 150) == nil)

        session.junctionMeters = [pulled - RouteTrimSession.maximumPullMeters - 1]
        session.move(.end, to: session.totalMeters)
        #expect(session.pullBounds(around: pulled, reach: 150) == (pulled - 150)...(pulled + 150))
    }

    @Test("a pull draws the stretch through the spot: along what the router finds, or straight")
    func pullingThroughASpot() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let via = CLLocationCoordinate2D(
            latitude: Line.latitude + 4.5 * Line.spacing,
            longitude: Line.longitude + 0.001
        )
        let stretch = Self.distances[3]...Self.distances[6]

        let routed = await visit(hike, in: context, router: DetourRouter())
        routed.move(.start, to: Self.distances[1])
        #expect(await routed.reroute(stretch, through: via))

        // The start cut is a step now, and the stretch is measured from it.
        let made = (Self.distances[3] - Self.distances[1])...(Self.distances[6] - Self.distances[1])
        guard case .replace(let range, let path)? = routed.steps.last else {
            Issue.record("a pull should be a stretch replaced")
            return
        }
        #expect(routed.steps.first == .trim(Self.distances[1]...Self.distances[10], endPauses: 0))
        #expect(range.lowerBound.isApproximatelyEqual(to: made.lowerBound, absoluteTolerance: 0.001))
        #expect(range.upperBound.isApproximatelyEqual(to: made.upperBound, absoluteTolerance: 0.001))
        #expect(path.count == 5, "two legs, each with its way round, meeting at the spot")
        let drawn = try #require(routed.line?.route)
        #expect(drawn.first?.latitude == Self.route[1].latitude)
        #expect(drawn.contains { $0.latitude.isApproximatelyEqual(to: via.latitude, absoluteTolerance: 1e-6) })

        let straight = await visit(hike, in: context)
        #expect(await straight.reroute(stretch, through: via))
        #expect(straight.steps == [.replace(stretch, with: RoutePath([via]))])
        #expect(straight.line?.route.count == 4 + 1 + 5)
    }
}
