//
//  LibraryTotalsSameGroundTests.swift
//  OpenHikesTests
//
//  Which clocked hikes take time out of a followed walk in *Totals*. Every
//  clock in the library used to: a friend's timed GPX from another trail,
//  imported for the same afternoon, cut the hiker's own walk down or out of
//  the totals altogether. A clock now counts against a walk only when its
//  line lies where the walk's trail does — the recording *Record Instead*
//  began with the walk's ground, the watch's recording of the same walk —
//  or when where it lies is not known.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Library totals: the same ground")
struct LibraryTotalsSameGroundTests {
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let trailID = UUID()

    private static func at(_ minutes: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// The trail, north of the Königssee, and somewhere else entirely.
    private static let alps = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.95, lonSpan: 0.05)
    private static let zurich = LibraryFootprint(southLat: 47.36, northLat: 47.40, westLon: 8.50, lonSpan: 0.05)

    private static let trail = LibraryHikeFacts(
        hikeID: trailID,
        title: "Trail",
        date: at(-100_000),
        distanceMeters: 6000,
        climbMeters: 400,
        highestMeters: 1200,
        movingSeconds: nil,
        clock: nil,
        isFromCommunity: false,
        footprint: alps
    )

    private static func clocked(_ start: Int, _ end: Int, lying footprint: LibraryFootprint?) -> LibraryHikeFacts {
        LibraryHikeFacts(
            hikeID: UUID(),
            title: "Clocked",
            date: at(start),
            distanceMeters: 1000,
            climbMeters: 50,
            highestMeters: 900,
            movingSeconds: TimeInterval((end - start) * 60),
            clock: DateInterval(start: at(start), end: at(end)),
            isFromCommunity: false,
            footprint: footprint
        )
    }

    private static let walk = LibraryWalkFacts(
        hikeID: trailID,
        startedAt: at(0),
        endedAt: at(240),
        coveredMeters: 6000,
        walkedMeters: 7000,
        activeSeconds: 240 * 60,
        climbMeters: 400,
        isRecordingsOwn: false,
        trailHasChanged: false
    )

    private static func walkOuting(with other: LibraryHikeFacts) -> LibraryOuting? {
        LibraryTotals.outings(hikes: [trail, other], walks: [walk]).first(where: \.isWalk)
    }

    // MARK: Counting

    @Test("a timed GPX from another trail over the walk's hours takes nothing from it")
    func anotherTrailsGPXTakesNothing() throws {
        let outing = try #require(Self.walkOuting(with: Self.clocked(60, 180, lying: Self.zurich)))

        #expect(outing.distanceMeters == Self.walk.coveredMeters)
        #expect(outing.movingSeconds == Self.walk.activeSeconds)
    }

    /// *Record Instead*: the recording begins with the walk's ground, clocked
    /// over the very time the walk's row spans, so the walk is its copy.
    @Test("the recording Record Instead handed the walk to still takes its time out")
    func recordInsteadStillTakesTheWalkOut() {
        let recording = Self.clocked(0, 300, lying: Self.alps)

        #expect(Self.walkOuting(with: recording) == nil, "the walk is wholly inside the recording")
    }

    @Test("a clocked hike on the same ground takes out the hours it shares")
    func sameGroundTakesItsShare() throws {
        let watch = LibraryFootprint(southLat: 47.58, northLat: 47.62, westLon: 12.97, lonSpan: 0.04)

        let outing = try #require(Self.walkOuting(with: Self.clocked(60, 180, lying: watch)))

        #expect(outing.distanceMeters == Self.walk.coveredMeters / 2)
    }

    @Test("a clocked hike whose line is not known still counts against the walk")
    func unknownGroundCountsAsBefore() throws {
        let outing = try #require(Self.walkOuting(with: Self.clocked(60, 180, lying: nil)))

        #expect(outing.distanceMeters == Self.walk.coveredMeters / 2)
    }

    // MARK: Where a line lies

    @Test("boxes meet when they overlap, or come within the margin")
    func boxesMeetWithinTheMargin() {
        // A trail drawn along a meridian has no width; a recording 50 m east
        // of it has to meet it all the same.
        let meridian = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.95, lonSpan: 0)
        let beside = LibraryFootprint(southLat: 47.55, northLat: 47.60, westLon: 12.9507, lonSpan: 0)

        #expect(meridian.meets(beside, within: LibraryTotals.sameGroundMarginMeters))
        #expect(!meridian.meets(beside, within: 0))
        #expect(!Self.alps.meets(Self.zurich, within: LibraryTotals.sameGroundMarginMeters))
        #expect(Self.alps.meets(Self.alps, within: 0))
    }

    @Test("boxes either side of the antimeridian meet across it")
    func boxesMeetAcrossTheAntimeridian() {
        let east = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: 179.95, lonSpan: 0.1)
        let west = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: -179.98, lonSpan: 0.02)
        let farWest = LibraryFootprint(southLat: -17.80, northLat: -17.70, westLon: -170, lonSpan: 0.02)

        #expect(east.meets(west, within: 0))
        #expect(west.meets(east, within: 0))
        #expect(!east.meets(farWest, within: LibraryTotals.sameGroundMarginMeters))
    }

    // MARK: Read from the library

    /// End to end through the sweep, which is where a hike's box comes from:
    /// its line.
    @Test("the sweep reads where each line lies, and a far-off GPX leaves the walk whole")
    func sweepReadsFootprints() async throws {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let trailLine = (0...10).map { RouteCoordinate(latitude: 47.55 + Double($0) * 0.005, longitude: 12.97) }
        let ridge = Fixture.hike(in: context, title: "Ridge Loop", route: trailLine)
        let friendsLine = (0...10).map { step in
            RouteCoordinate(
                latitude: 47.36 + Double(step) * 0.003,
                longitude: 8.52,
                timestamp: Self.at(60 + step * 10)
            )
        }
        _ = Fixture.hike(in: context, title: "A friend's walk", route: friendsLine)
        context.insert(
            HikeWalk(
                hikeID: ridge.id,
                startedAt: Self.at(0),
                endedAt: Self.at(240),
                activeSeconds: 240 * 60,
                coveredIntervals: [0, 4000],
                furthestDistanceMeters: 4000,
                routeDistanceMeters: 5500,
                endReason: .ended
            )
        )
        try context.save()

        let read = try await LibraryTotalsSweep.read(from: container)
        let outings = LibraryTotals.outings(hikes: read.hikes, walks: read.walks)

        #expect(read.hikes.allSatisfy { $0.footprint != nil })
        #expect(outings.first(where: \.isWalk)?.distanceMeters == 4000)
        #expect(outings.count == 2, "the friend's walk is an outing too")
    }
}
