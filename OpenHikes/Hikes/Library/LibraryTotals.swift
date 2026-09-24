//
//  LibraryTotals.swift
//  OpenHikes
//
//  How far the hiker has walked: this year, last year and all time, summed
//  across the library — the payoff for having recorded every walk.
//
//  ## What counts, which is three decisions rather than a default
//
//  Settled by the owner, and pinned by `LibraryTotalsTests`:
//
//  - **A hike counts as walked when it carries a clock** — a recording, or a
//    GPX with timestamps. There is no column that says "recorded by me", so a
//    timed file from a friend counts too, and the screen says so. A trail
//    saved from the community, and a drawn or planned line with no clock, is
//    in the library without having been walked, and counts once it is.
//  - **A walk along a saved trail is its own outing**, measured by what it
//    covered, not by the trail's length: a trail walked six times is six
//    walks and one `Hike`, and summing `Hike.distanceMeters` would be off by
//    six for exactly the hikers this is for. The ``TrailWalkEndReason/recorded``
//    walk a recording writes of itself is left out — the recording already
//    counted, and counting its walk would count it twice.
//  - **The year is the walk's own**: a clocked hike's `date` is its first
//    stamp, and a walk's is when it started. The import date — what a
//    clockless hike's `date` is — never places anything in a year, because a
//    clockless hike never counts.
//
//  A followed walk's climb is the trail's climb in proportion to what was
//  covered. Nothing measured the climb of the stretches themselves, and the
//  proportion is closer than counting the whole trail or none of it.
//
//  Following a trail and recording are independent — starting a recording
//  leaves a walk under way alone — so one afternoon can leave both a
//  recording and a walk along the trail it followed. A followed walk whose
//  time overlaps a counted hike's clock is that afternoon's second copy, and
//  is left out: the recording is the whole of it, the walk only the stretch
//  that lay on the trail.
//
//  A record is one outing, not one trail: the longest is the furthest anyone
//  walked in one go, so a thirty-kilometre trail walked for two is a
//  two-kilometre record. Only the highest is the trail's, because coverage
//  says how far a walk went and not whether it reached the top.
//
//  ## Where it is worked out
//
//  Not in a body. Every route in the library is walked once, off the main
//  actor, in a context of its own — the shape ``HikeListMetrics`` takes — and
//  what comes back is values: ``LibraryOuting``s, arithmetic over which is
//  ordinary to assert.
//

import Foundation
import OpenHikesData
import SwiftData

/// One walk the hiker actually made: a clocked hike, or one walk along a
/// saved trail.
nonisolated struct LibraryOuting: Equatable, Sendable {
    let hikeID: UUID
    let date: Date
    let distanceMeters: Double
    let climbMeters: Double
    let movingSeconds: TimeInterval
}

/// A hike that was walked, with the figures its records are chosen by.
nonisolated struct LibraryRecordCandidate: Equatable, Sendable {
    let hikeID: UUID
    let title: String
    let distanceMeters: Double
    let climbMeters: Double?
    let highestMeters: Double?
}

/// One hike as the sweep read it — everything the counting rules ask of it.
nonisolated struct LibraryHikeFacts: Equatable, Sendable {
    let hikeID: UUID
    let title: String
    let date: Date
    let distanceMeters: Double
    let climbMeters: Double?
    let highestMeters: Double?
    let movingSeconds: TimeInterval?
    /// First stamp to last, or `nil` for a hike with no clock.
    let clock: DateInterval?
    let isFromCommunity: Bool

    var hasClock: Bool { clock != nil }
}

/// One walk along a saved trail, as the sweep read it.
nonisolated struct LibraryWalkFacts: Equatable, Sendable {
    let hikeID: UUID
    let startedAt: Date
    let endedAt: Date
    let coveredMeters: Double
    let routeDistanceMeters: Double
    let activeSeconds: TimeInterval
    let isRecordingsOwn: Bool
}

nonisolated struct LibraryTotals: Equatable, Sendable {
    /// The five figures a period is summed into.
    struct Figures: Equatable, Sendable {
        var distanceMeters = 0.0
        var climbMeters = 0.0
        var movingSeconds: TimeInterval = 0
        /// Outings, not hikes: a trail walked twice is two.
        var outings = 0
        /// Distinct trails among them.
        var trails = 0

        init(_ outings: some Sequence<LibraryOuting>) {
            var trailIDs = Set<UUID>()
            for outing in outings {
                distanceMeters += outing.distanceMeters
                climbMeters += outing.climbMeters
                movingSeconds += outing.movingSeconds
                self.outings += 1
                trailIDs.insert(outing.hikeID)
            }
            trails = trailIDs.count
        }
    }

    let year: Int
    let thisYear: Figures
    let lastYear: Figures
    let allTime: Figures
    /// Distance by month, January first, twelve entries each.
    let monthsThisYear: [Double]
    let monthsLastYear: [Double]
    let longest: LibraryRecordCandidate?
    let highest: LibraryRecordCandidate?
    let steepest: LibraryRecordCandidate?

    /// How long a hike has to be before its gradient is a record rather than
    /// a steep few hundred metres of a driveway.
    static let steepestMinimumMeters = 1000.0

    init(
        hikes: [LibraryHikeFacts],
        walks: [LibraryWalkFacts],
        year: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        let outings = Self.outings(hikes: hikes, walks: walks)
        let yearOf = { (outing: LibraryOuting) in calendar.component(.year, from: outing.date) }
        self.year = year
        thisYear = Figures(outings.filter { yearOf($0) == year })
        lastYear = Figures(outings.filter { yearOf($0) == year - 1 })
        allTime = Figures(outings)
        monthsThisYear = Self.months(of: outings, in: year, calendar: calendar)
        monthsLastYear = Self.months(of: outings, in: year - 1, calendar: calendar)

        let byID = Self.byID(hikes)
        let candidates = outings.compactMap { outing -> LibraryRecordCandidate? in
            guard let hike = byID[outing.hikeID] else { return nil }
            return LibraryRecordCandidate(
                hikeID: hike.hikeID,
                title: hike.title,
                distanceMeters: outing.distanceMeters,
                climbMeters: hike.climbMeters == nil ? nil : outing.climbMeters,
                highestMeters: hike.highestMeters
            )
        }
        longest = candidates.max { $0.distanceMeters < $1.distanceMeters }
        highest = candidates.filter { $0.highestMeters != nil }
            .max { ($0.highestMeters ?? 0) < ($1.highestMeters ?? 0) }
        steepest = candidates
            .filter { $0.distanceMeters >= Self.steepestMinimumMeters && $0.climbMeters != nil }
            .max { Self.gradient($0) < Self.gradient($1) }
    }

    /// Every outing in the library, by the rules the file header gives.
    static func outings(hikes: [LibraryHikeFacts], walks: [LibraryWalkFacts]) -> [LibraryOuting] {
        let byID = byID(hikes)
        let counted = hikes.filter { $0.hasClock && !$0.isFromCommunity }
        let clocks = counted.compactMap(\.clock)
        let clocked = counted.map { hike in
            LibraryOuting(
                hikeID: hike.hikeID,
                date: hike.date,
                distanceMeters: hike.distanceMeters,
                climbMeters: hike.climbMeters ?? 0,
                movingSeconds: hike.movingSeconds ?? 0
            )
        }
        let followed = walks.filter { walk in
            !walk.isRecordingsOwn
                && !clocks.contains { walk.startedAt < $0.end && walk.endedAt > $0.start }
        }
        .map { walk in
            let fraction = walk.routeDistanceMeters > 0
                ? min(1, max(0, walk.coveredMeters / walk.routeDistanceMeters))
                : 0
            return LibraryOuting(
                hikeID: walk.hikeID,
                date: walk.startedAt,
                distanceMeters: walk.coveredMeters,
                climbMeters: (byID[walk.hikeID]?.climbMeters ?? 0) * fraction,
                movingSeconds: walk.activeSeconds
            )
        }
        return clocked + followed
    }

    private static func byID(_ hikes: [LibraryHikeFacts]) -> [UUID: LibraryHikeFacts] {
        Dictionary(hikes.map { ($0.hikeID, $0) }) { first, _ in first }
    }

    private static func months(of outings: [LibraryOuting], in year: Int, calendar: Calendar) -> [Double] {
        var months = Array(repeating: 0.0, count: 12)
        for outing in outings {
            let parts = calendar.dateComponents([.year, .month], from: outing.date)
            guard parts.year == year, let month = parts.month, (1...12).contains(month) else { continue }
            months[month - 1] += outing.distanceMeters
        }
        return months
    }

    private static func gradient(_ candidate: LibraryRecordCandidate) -> Double {
        guard candidate.distanceMeters > 0 else { return 0 }
        return (candidate.climbMeters ?? 0) / candidate.distanceMeters
    }
}

// MARK: - Reading the library

nonisolated enum LibraryTotalsSweep {
    /// Every hike and walk in `container`, read once in a context of its own
    /// and walked into values. `@concurrent`, so a library as long as a
    /// hiker's walking life is walked off the main actor.
    @concurrent
    static func read(from container: ModelContainer) async -> (hikes: [LibraryHikeFacts], walks: [LibraryWalkFacts]) {
        assertOffMainThread("Summing the library walks every route, and must stay off the main thread")
        let context = ModelContext(container)
        let hikes = (try? context.fetch(FetchDescriptor<Hike>())) ?? []
        let hikeFacts = hikes.compactMap { hike -> LibraryHikeFacts? in
            // A recording still being drawn is not a walk yet.
            guard !hike.isRecording else { return nil }
            let statistics = HikeRouteStatistics(distanceMeters: hike.distanceMeters, route: hike.route)
            return LibraryHikeFacts(
                hikeID: hike.id,
                title: hike.displayTitle,
                date: hike.date,
                distanceMeters: hike.distanceMeters,
                climbMeters: statistics.elevationGain?.converted(to: .meters).value,
                highestMeters: statistics.maxElevation?.converted(to: .meters).value,
                movingSeconds: statistics.movingDuration ?? statistics.duration,
                clock: statistics.duration == nil ? nil : statistics.startDate.flatMap { start in
                    statistics.endDate.map { DateInterval(start: start, end: max(start, $0)) }
                },
                isFromCommunity: hike.importedFromListingID != nil
            )
        }
        let walks = (try? context.fetch(FetchDescriptor<HikeWalk>())) ?? []
        let walkFacts = walks.map { walk in
            LibraryWalkFacts(
                hikeID: walk.hikeID,
                startedAt: walk.startedAt,
                endedAt: walk.endedAt,
                coveredMeters: walk.coverage.coveredMeters,
                routeDistanceMeters: walk.routeDistanceMeters,
                activeSeconds: walk.activeSeconds,
                isRecordingsOwn: walk.endReason == .recorded
            )
        }
        return (hikeFacts, walkFacts)
    }
}
