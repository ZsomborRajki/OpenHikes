//
//  LibraryTotalsSameGroundTests.swift
//  OpenHikesTests
//
//  Which clocked hikes take time out of a followed walk in *Totals*. Every
//  clock in the library used to: a friend's timed GPX from another trail,
//  imported for the same afternoon, cut the hiker's own walk down or out of
//  the totals altogether. A clock now counts against a walk only when its
//  hike lay where the walk went — the recording *Record Instead* began with
//  the walk's ground, the watch's recording of the same walk — or when where
//  either lay is not known. Each side is the ground of the hours weighed:
//  the stretches the walk covered, and the hike's line over its clock.
//
//  How a box is read off a line, and when two meet, is
//  `LibraryFootprintTests`.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@Suite("Library totals: the same ground")
struct LibraryTotalsSameGroundTests {
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let trailID = UUID()

    private static func at(_ minutes: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Where the walk went, north of the Königssee, and somewhere else
    /// entirely.
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
        isFromCommunity: false
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

    private static func followed(_ start: Int, _ end: Int, lying footprint: LibraryFootprint?) -> LibraryWalkFacts {
        LibraryWalkFacts(
            hikeID: trailID,
            startedAt: at(start),
            endedAt: at(end),
            coveredMeters: 6000,
            walkedMeters: 7000,
            activeSeconds: TimeInterval((end - start) * 60),
            climbMeters: 400,
            isRecordingsOwn: false,
            trailHasChanged: false,
            footprint: footprint
        )
    }

    private static let walk = followed(0, 240, lying: alps)

    private static func walkOuting(with other: LibraryHikeFacts, walking: LibraryWalkFacts? = nil) -> LibraryOuting? {
        LibraryTotals.outings(hikes: [trail, other], walks: [walking ?? walk]).first(where: \.isWalk)
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

    /// A walk along a line its trail has been redrawn from since: its
    /// stretches are metres along a line that is gone, so where it went is
    /// not known, and the clock of a recording that holds its ground has to
    /// take it out wherever the trail lies now.
    @Test("a walk whose ground is not known loses the time of every clock over it")
    func walkOfUnknownGroundCountsEveryClock() throws {
        let unplaced = Self.followed(0, 240, lying: nil)

        let outing = try #require(Self.walkOuting(with: Self.clocked(60, 180, lying: Self.zurich), walking: unplaced))

        #expect(outing.distanceMeters == unplaced.coveredMeters / 2)
    }

    /// Clocks on the walk's ground, elsewhere and of no known ground, laid
    /// down at random over a few weeks, held to a scan of every clock for
    /// every walk: the search that finds a walk's clocks finds all of them.
    @Test("a library's outings are a scan's of every clock on each walk's ground", arguments: [3, 58, 1658])
    func libraryMatchesTheScan(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let grounds: [LibraryFootprint?] = [Self.alps, Self.zurich, nil]
        let span = 30 * 24 * 60
        let hikes = [Self.trail] + (0..<300).map { _ in
            let start = Int.random(in: 0..<span, using: &generator)
            let ground = grounds[Int.random(in: grounds.indices, using: &generator)]
            return Self.clocked(start, start + Int.random(in: 0...300, using: &generator), lying: ground)
        }
        let walks = (0..<300).map { _ in
            let start = Int.random(in: 0..<span, using: &generator)
            let ground = grounds[Int.random(in: grounds.indices, using: &generator)]
            return Self.followed(start, start + Int.random(in: 1...600, using: &generator), lying: ground)
        }

        let shares = LibraryTotals.outings(hikes: hikes, walks: walks).filter(\.isWalk).map(\.movingSeconds)

        let scanned = walks.map { Self.scannedSeconds(of: $0, against: hikes) }.filter { $0 > 0 }
        #expect(shares == scanned, "seed \(seed)")
        #expect(scanned.count < walks.count, "some walks should be wholly recorded")
    }

    /// What is left of `walk`'s time once every clock in `hikes` that could
    /// be on its ground is taken out, found by looking at every one.
    private static func scannedSeconds(of walk: LibraryWalkFacts, against hikes: [LibraryHikeFacts]) -> TimeInterval {
        let length = walk.endedAt.timeIntervalSince(walk.startedAt)
        let overlaps = hikes.compactMap { hike -> (start: Date, end: Date)? in
            guard let clock = hike.clock, LibraryTotals.couldShareGround(hike.footprint, walk.footprint) else {
                return nil
            }
            let start = max(clock.start, walk.startedAt)
            let end = min(clock.end, walk.endedAt)
            return start < end ? (start, end) : nil
        }
        .sorted { $0.start < $1.start }
        var recorded: TimeInterval = 0
        var reach = walk.startedAt
        for overlap in overlaps where overlap.end > reach {
            recorded += overlap.end.timeIntervalSince(max(overlap.start, reach))
            reach = overlap.end
        }
        return walk.activeSeconds * max(0, 1 - recorded / length)
    }

    // MARK: Read from the library

    /// A trail 16.7 km long, due north, and a walk over its first 1.1 km in
    /// the first ten minutes, along the line as it is drawn now.
    private static let longTrail = (0...10).map { step in
        RouteCoordinate(latitude: 47.55 + Double(step) * 0.015, longitude: 12.97)
    }

    private static let walkedMeters = 1100.0

    /// The library with the long trail, the walk along it, and `track`.
    private static func library(beside track: [RouteCoordinate]) throws -> ModelContainer {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let longOne = Fixture.hike(in: context, title: "Long Trail", route: longTrail)
        _ = Fixture.hike(in: context, title: "A timed GPX", route: track)
        context.insert(
            HikeWalk(
                hikeID: longOne.id,
                startedAt: at(0),
                endedAt: at(10),
                activeSeconds: 600,
                coveredIntervals: [0, walkedMeters],
                furthestDistanceMeters: walkedMeters,
                routeDistanceMeters: longOne.distanceMeters,
                endReason: .ended,
                routeRevision: TrailWalkRecord.routeRevision(of: longTrail)
            )
        )
        try context.save()
        return container
    }

    /// The walk's outing, read through the sweep with `track` saved beside
    /// the trail.
    private static func walkOuting(beside track: [RouteCoordinate]) async throws -> LibraryOuting? {
        let read = try await LibraryTotalsSweep.read(from: library(beside: track))
        return LibraryTotals.outings(hikes: read.hikes, walks: read.walks).first(where: \.isWalk)
    }

    /// A line due north from `latitude`, a hundred metres east of the trail,
    /// stamped every minute over `minutes`.
    private static func track(from latitude: Double, over minutes: ClosedRange<Int>) -> [RouteCoordinate] {
        minutes.map { minute in
            RouteCoordinate(
                latitude: latitude + Double(minute - minutes.lowerBound) * 0.0005,
                longitude: 12.9713,
                timestamp: at(minute)
            )
        }
    }

    @Test("the sweep places a clock on its stamped line and a walk on what it covered, and nothing else")
    func sweepReadsWhereEachLay() async throws {
        let read = try await LibraryTotalsSweep.read(from: Self.library(beside: Self.track(from: 47.551, over: 0...5)))

        let walked = try #require(read.walks.first?.footprint)
        #expect(walked.southLat == 47.55)
        #expect(walked.northLat.isApproximatelyEqual(to: 47.5599, absoluteTolerance: 1e-4))
        let clocked = read.hikes.filter(\.hasClock)
        let unclocked = read.hikes.filter { !$0.hasClock }
        #expect(clocked.map(\.footprint) == [LibraryFootprint(clockedPartOf: Self.track(from: 47.551, over: 0...5))])
        #expect(unclocked.map(\.footprint) == [nil], "a trail with no clock is never weighed")
    }

    /// The trail's box holds the far end, fourteen kilometres from anything
    /// the walk covered: the walk's ground is the stretch it covered.
    @Test("a GPX of the same minutes beside the trail's far end leaves the walk whole")
    func gpxBesideTheFarEndLeavesTheWalk() async throws {
        let outing = try #require(try await Self.walkOuting(beside: Self.track(from: 47.69, over: 0...10)))

        #expect(outing.distanceMeters == Self.walkedMeters)
    }

    /// The line's untimed start lies on the trail, where the walk went; its
    /// clock is the time of the stamped part alone, fifty kilometres north.
    @Test("a GPX whose stamped part lies elsewhere leaves the walk whole, though its untimed start is on the trail")
    func gpxStampedElsewhereLeavesTheWalk() async throws {
        var track = Self.track(from: 48.0, over: 0...10)
        track[0].boundary = .paused
        let onTheTrail = Self.longTrail.prefix(2)

        let outing = try #require(try await Self.walkOuting(beside: onTheTrail + track))

        #expect(outing.distanceMeters == Self.walkedMeters)
    }

    @Test("a GPX of the same minutes beside the stretch the walk covered takes out its share")
    func gpxBesideTheCoveredStretchTakesItsShare() async throws {
        let outing = try #require(try await Self.walkOuting(beside: Self.track(from: 47.551, over: 0...5)))

        #expect(outing.distanceMeters.isApproximatelyEqual(to: Self.walkedMeters / 2, absoluteTolerance: 1e-9))
    }
}
