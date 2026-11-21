//
//  RouteTrimSessionTests.swift
//  OpenHikesTests
//
//  One visit to *Edit Route*: where the cuts may stand, how a handle slides
//  along its line, what a save refuses, and when the map is shown the cuts.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Route trim session")
struct RouteTrimSessionTests {
    private enum Line {
        static let start = Date(timeIntervalSince1970: 1_750_000_000)
        static let latitude = 47.63
        static let longitude = 12.86
        /// A thousandth of a degree of latitude between points, about 111 m.
        static let spacing = 0.001
        static let secondsPerPoint: TimeInterval = 60
        /// Far enough east for the way back to be a line of its own, as an
        /// out-and-back's two legs are when each was sampled.
        static let returnOffset = 0.00002
    }

    private static func point(_ step: Double, at index: Int, east: Double = 0) -> RouteCoordinate {
        RouteCoordinate(
            latitude: Line.latitude + step * Line.spacing,
            longitude: Line.longitude + east,
            timestamp: Line.start.addingTimeInterval(Double(index) * Line.secondsPerPoint)
        )
    }

    /// Eleven points north along a meridian.
    private static let route = (0...10).map { point(Double($0), at: $0) }
    /// Five steps north and the same five back, beside the way out.
    private static let outAndBack = (0...5).map { point(Double($0), at: $0) }
        + (1...5).map { point(Double(5 - $0), at: 5 + $0, east: Line.returnOffset) }

    private static func loaded(_ route: [RouteCoordinate] = route) async -> RouteTrimSession {
        let session = RouteTrimSession()
        await session.load(route)
        return session
    }

    private static func step(_ count: Double, of session: RouteTrimSession) -> Double {
        session.totalMeters * count / 10
    }

    // MARK: The line

    @Test("a loaded line starts with both cuts at its ends")
    func loadingStartsWhole() async {
        let session = await Self.loaded()

        #expect(session.lineRevision == 1)
        #expect(session.startMeters == 0)
        #expect(session.endMeters == session.totalMeters)
        #expect(session.trim == nil)
        #expect(!session.hasChanges)
        #expect(await session.editedLine() == nil, "nothing is cut, so there is nothing to save")
    }

    @Test("the same line again keeps the cuts, and a new one starts over")
    func reloading() async {
        let session = await Self.loaded()
        session.move(.end, to: Self.step(6, of: session))

        await session.load(Self.route)
        #expect(session.lineRevision == 1)
        #expect(session.endMeters.isApproximatelyEqual(to: Self.step(6, of: session), absoluteTolerance: 0.01))

        await session.load(Array(Self.route[0...6]))
        #expect(session.lineRevision == 2)
        #expect(session.endMeters == session.totalMeters)
    }

    @Test("a line too short to be one is not loaded")
    func tooShortToLoad() async {
        let session = RouteTrimSession()

        await session.load([Self.route[0]])

        #expect(session.line == nil)
        #expect(session.lineRevision == 0)
    }

    // MARK: The cuts

    @Test("a cut stays inside the line and short of the other")
    func cutsAreHeldApart() async {
        let session = await Self.loaded()
        let total = session.totalMeters

        session.move(.start, to: -40)
        #expect(session.startMeters == 0)
        session.move(.end, to: total + 40)
        #expect(session.endMeters == total)

        session.move(.end, to: Self.step(4, of: session))
        session.move(.start, to: Self.step(9, of: session))
        #expect(session.startMeters == session.endMeters - RouteTrimSession.minimumKeptMeters)

        session.move(.end, to: 0)
        #expect(session.endMeters == session.startMeters + RouteTrimSession.minimumKeptMeters)
        #expect(session.trim != nil)
        #expect(session.hasChanges)
    }

    @Test("a handle dragged on the map goes to the spot on the line nearest the finger")
    func aHandleSlidesAlongTheLine() async {
        let session = await Self.loaded()
        // Beside the line, level with its fourth step.
        let finger = CLLocationCoordinate2D(
            latitude: Line.latitude + 4 * Line.spacing,
            longitude: Line.longitude + 0.0004
        )

        session.move(.start, toward: finger)

        #expect(session.startMeters.isApproximatelyEqual(to: Self.step(4, of: session), absoluteTolerance: 1))
    }

    @Test("a handle stays on its own leg of an out-and-back")
    func aHandleStaysOnItsLeg() async {
        let session = await Self.loaded(Self.outAndBack)
        let total = session.totalMeters
        // On the way out, two steps up — which the way back passes a metre
        // and a half beside, three steps before its end.
        let finger = CLLocationCoordinate2D(latitude: Line.latitude + 2 * Line.spacing, longitude: Line.longitude)

        session.move(.end, toward: finger)

        #expect(session.endMeters.isApproximatelyEqual(to: total * 0.8, absoluteTolerance: 2))
    }

    // MARK: A drive on an end

    /// The walk, then the drive home with the recording paused through it,
    /// stopped on the first fix after it, about 14 km on.
    private static let drivenHome = route + [
        RouteCoordinate(
            latitude: Line.latitude + 140 * Line.spacing,
            longitude: Line.longitude,
            timestamp: Line.start.addingTimeInterval(3 * 3600),
            boundary: .paused
        ),
    ]

    /// The drive has no length on the line, since a paused leg has none, so
    /// it stands on the line's own end: the offer was hidden, and moving the
    /// end there took nothing off.
    @Test("a drive the line ends on, paused, comes off in one tap and the walk keeps its length")
    func aDriveOnTheEndComesOff() async throws {
        let session = await Self.loaded(Self.drivenHome)
        let drive = try #require(session.line?.carriedEnds.trailing)
        let walked = try #require(Self.route.last)
        #expect(!session.hasTakenOff(drive, at: .end))

        session.takeOff(drive, at: .end)

        #expect(session.isTrimmed)
        #expect(session.hasTakenOff(drive, at: .end))
        #expect(session.spot(of: .end)?.coordinate.latitude == walked.latitude)
        #expect(session.timestamp(of: .end) == walked.timestamp)
        let edited = try #require(await session.editedLine())
        #expect(edited.route == Self.route)
        #expect(edited.removedMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01))
        #expect(edited.end == .cut(try #require(walked.timestamp)))
    }

    @Test("a handle dragged back to the end leaves the pause there, and a touch alone moves nothing")
    func aHandleByHandKeepsThePause() async throws {
        let session = await Self.loaded(Self.drivenHome)
        let drive = try #require(session.line?.carriedEnds.trailing)
        session.takeOff(drive, at: .end)

        // The chart's drag moves the cut to where it stands as a finger
        // comes down.
        session.move(.end, to: session.totalMeters)
        #expect(session.hasTakenOff(drive, at: .end))

        session.move(.end, to: Self.step(9, of: session))
        session.move(.end, to: session.totalMeters)

        #expect(!session.isTrimmed)
        #expect(!session.hasTakenOff(drive, at: .end))
        #expect(session.spot(of: .end)?.coordinate.latitude == Self.drivenHome.last?.latitude)
        #expect(session.timestamp(of: .end) == Self.drivenHome.last?.timestamp)
    }

    // MARK: Saving

    private func destination(
        for hike: Hike,
        in context: ModelContext,
        line: @escaping () -> [RouteCoordinate]
    ) -> RouteTrimSession.Destination {
        RouteTrimSession.Destination(hike: hike, context: context, settledLine: line)
    }

    @Test("a save writes the cuts into the hike")
    func savingWritesTheCuts() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let session = await Self.loaded()
        session.move(.end, to: Self.step(6, of: session))

        let landed = await session.save(to: destination(for: hike, in: context) { Self.route })

        #expect(landed)
        #expect(hike.route == Array(Self.route[0...6]))
        #expect(hike.originalRoute == Self.route)
        #expect(session.refusal == nil)
        #expect(!session.isSaving)
        #expect(session.workoutReplacement == nil, "a launch with no Health replaces nothing")
    }

    @Test("a line edited elsewhere since the cuts were made is not cut")
    func aChangedLineIsRefused() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let session = await Self.loaded()
        session.move(.end, to: Self.step(6, of: session))

        let elsewhere = Array(Self.route[0...8])
        let changed = await session.save(to: destination(for: hike, in: context) { elsewhere })
        #expect(!changed)
        #expect(session.refusal == .lineChanged)
        #expect(hike.route == Self.route)

        session.refusal = nil
        let unsettled = await session.save(to: destination(for: hike, in: context) { [] })
        #expect(!unsettled)
        #expect(session.refusal == .lineChanged)
    }

    @Test("a save with nothing cut does nothing")
    func nothingToSave() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let session = await Self.loaded()

        let landed = await session.save(to: destination(for: hike, in: context) { Self.route })

        #expect(!landed)
        #expect(session.refusal == nil)
        #expect(hike.originalRoute.isEmpty)
    }

    @Test("a revert puts the original back, and says why when it cannot")
    func reverting() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        let session = await Self.loaded()
        session.move(.end, to: Self.step(6, of: session))
        await session.save(to: destination(for: hike, in: context) { Self.route })
        let trimmed = hike.route

        #expect(!session.revert(in: destination(for: hike, in: context) { [] }))
        #expect(session.refusal == .lineChanged)
        session.refusal = nil

        #expect(session.revert(in: destination(for: hike, in: context) { trimmed }))
        #expect(hike.route == Self.route)

        #expect(!session.revert(in: destination(for: hike, in: context) { Self.route }))
        #expect(session.refusal == .noOriginal)
    }

    // MARK: The map

    @Test("the map is shown a visit's cuts until the visit ends, and never after")
    func theMapSeesOneVisit() {
        let preview = RouteTrimPreview()
        let session = RouteTrimSession()
        let other = RouteTrimSession()

        session.show(on: preview)
        #expect(preview.session === session)

        // A visit that is not the one on the map takes nothing off it.
        other.end()
        #expect(preview.session === session)

        session.end()
        #expect(preview.session == nil)

        // The pop that ended it builds its screen once more on the way out.
        session.show(on: preview)
        #expect(preview.session == nil)
    }
}
