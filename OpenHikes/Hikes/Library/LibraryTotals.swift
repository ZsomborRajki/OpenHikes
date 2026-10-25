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
//  A followed walk's climb is its own: each stretch it covered, climbed the
//  way it was walked — ``RouteProfile/climb(walking:)``, the share card's
//  figure. The trail's climb in proportion to what was covered gave a walk
//  down a trail the trail's ascent, and a walk over its flat half half of
//  it, and made an all-downhill walk the library's steepest (#1039). A
//  stretch walked there and back climbs both ways, as on the card, while
//  its distance is the ground covered, once. So *Steepest* spreads a walk's
//  climb over the length it walked, each stretch once per way it went —
//  ``TrailWalkCoverage/walkedMeters``, which is what a recording's distance
//  already is — and not over that distance, over which up a hill and back
//  down it would read twice as steep as it was, and could take the record
//  from a steeper recording.
//
//  Following a trail and recording are independent — starting a recording
//  leaves a walk under way alone — so one afternoon can leave both a
//  recording and a walk along the trail it followed. Whatever part of a
//  followed walk's time a counted hike's clock also covers is that
//  afternoon's second copy, and is left out: the recording is the whole of
//  it, the walk only the stretch that lay on the trail. The rest of the walk
//  still counts, in proportion to the time left over — a ten-minute
//  recording in the middle of a four-hour walk takes ten minutes out of it,
//  not the four hours. A walk kept only by a figure for the whole of it
//  cannot say which kilometres fell in which minutes, so the proportion is
//  an even pace's; a walk wholly inside a recording is left out entirely.
//
//  A record is one outing, not one trail: the longest is the furthest anyone
//  walked in one go, so a thirty-kilometre trail walked for two is a
//  two-kilometre record. Only the highest is the trail's, because coverage
//  says how far a walk went and not whether it reached the top.
//
//  Both figures a walk takes from its trail — the climb along its stretches
//  and the highest point — are read off the line the trail draws now, and
//  the stretches are metres along the line the walk was walked on. *Edit
//  Route* keeps the walks along a drawn trail as history and redraws the
//  line under them, here or on the other device, and nothing kept the
//  heights of the line they were walked along: that would be more mirrored
//  columns on ``HikeWalk`` for a figure only that walk asks for. So a
//  walk whose ``HikeWalk/routeRevision`` is not the route's, or that names
//  no line at all, still counts as an outing, with the distance and the time
//  it measured itself, but adds no climb and is never the highest or the
//  steepest; it can still be the longest (#912). The screen says so whenever
//  one is left out, and ``WalkSummaryView`` will not draw or climb such a
//  walk's stretches for the same reason.
//
//  ## The months are the hiker's calendar's
//
//  The year is the one the hiker's own calendar is in — the screen is
//  headed with it — and so are its months, rather than a Gregorian January
//  to December under, say, a Hebrew year's heading. A year is then not
//  always twelve months: a Hebrew leap year has thirteen (Foundation numbers
//  Adar I as 6, and a common year skips it, so Elul is 13 in both), every
//  Ethiopic and Coptic year has thirteen, and a Chinese leap year repeats a
//  month under the same number. So a year's months are read off the
//  calendar, one after another from the year's first day to its last, and a
//  month is its number plus whether it is that repeat. Every outing a year
//  counts is in one of its bars (#1079), and this year is laid beside last
//  year month for month, a month only one of them has standing alone.
//
//  ## Where it is worked out
//
//  Not in a body. Every route in the library is walked once, off the main
//  actor, in a context of its own — the shape ``HikeListMetrics`` takes — and
//  what comes back is values: ``LibraryOuting``s, arithmetic over which is
//  ordinary to assert.
//

import Algorithms
import Foundation
import OpenHikesData
import SwiftData

/// One walk the hiker actually made: a clocked hike, or one walk along a
/// saved trail.
nonisolated struct LibraryOuting: Equatable, Sendable {
    let hikeID: UUID
    let date: Date
    /// How far the outing went, which the distance totals add up and
    /// *Longest* is chosen by: a clocked hike's distance, and the ground a
    /// walk covered, where a stretch walked there and back counts once.
    let distanceMeters: Double
    /// The length walked, which *Steepest* spreads ``climbMeters`` over: a
    /// clocked hike's distance again, and a walk's stretches once per way it
    /// walked them, since its climb counts both ways — see the file header.
    let walkedMeters: Double
    /// `nil` for a walk along a line its trail has been redrawn from since,
    /// whose climb nothing kept.
    let climbMeters: Double?
    let movingSeconds: TimeInterval
    /// One walk along a saved trail rather than a clocked hike: the trail is
    /// what it is called, and its time is its own ``movingSeconds`` rather
    /// than any clock the trail carries.
    let isWalk: Bool
}

/// A hike that was walked, with the figures its records are chosen by.
nonisolated struct LibraryRecordCandidate: Equatable, Sendable {
    let hikeID: UUID
    let title: String
    let distanceMeters: Double
    /// The outing's ``LibraryOuting/walkedMeters``.
    let walkedMeters: Double
    let climbMeters: Double?
    let highestMeters: Double?

    /// What *Steepest* is chosen by: the climb over the length walked, not
    /// over ``distanceMeters``, where a walk counts a stretch walked there
    /// and back once.
    var gradient: Double {
        guard walkedMeters > 0 else { return 0 }
        return (climbMeters ?? 0) / walkedMeters
    }
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
    /// Each stretch once per way it was walked —
    /// ``TrailWalkCoverage/walkedMeters``, the length ``climbMeters`` climbs.
    let walkedMeters: Double
    let activeSeconds: TimeInterval
    /// What the walk itself climbed: each stretch it covered, the way it was
    /// walked, along the line the trail draws now. 0 when that line has no
    /// heights, and not read when ``trailHasChanged``, since the stretches
    /// are metres along another line.
    let climbMeters: Double
    let isRecordingsOwn: Bool
    /// The trail has been redrawn since this walk: the route's revision is not
    /// the one the walk was measured along, or the walk names none — the test
    /// ``WalkSummaryView`` makes. `false` for a walk whose trail is not among
    /// the hikes the sweep sums, since nothing is known to have changed about
    /// a line that is not there.
    let trailHasChanged: Bool
}

nonisolated struct LibraryTotals: Equatable, Sendable {
    /// The figures a period is summed into.
    struct Figures: Equatable, Sendable {
        var distanceMeters = 0.0
        /// Leaves out the outings counted in ``outingsWithoutClimb``.
        var climbMeters = 0.0
        var movingSeconds: TimeInterval = 0
        /// Outings, not hikes: a trail walked twice is two.
        var outings = 0
        /// Distinct trails among them.
        var trails = 0
        /// Outings whose climb is not in ``climbMeters``: walks along a trail
        /// that has been redrawn since.
        var outingsWithoutClimb = 0

        init(_ outings: some Sequence<LibraryOuting>) {
            var trailIDs = Set<UUID>()
            for outing in outings {
                distanceMeters += outing.distanceMeters
                if let climb = outing.climbMeters {
                    climbMeters += climb
                } else {
                    outingsWithoutClimb += 1
                }
                movingSeconds += outing.movingSeconds
                self.outings += 1
                trailIDs.insert(outing.hikeID)
            }
            trails = trailIDs.count
        }
    }

    /// One month of the hiker's calendar, as it is laid beside the same month
    /// of the year before: its number, and whether it is the repeat of that
    /// number a Chinese leap year inserts after it.
    struct Month: Hashable, Comparable, Sendable {
        let number: Int
        let isLeap: Bool

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.number, lhs.isLeap ? 1 : 0) < (rhs.number, rhs.isLeap ? 1 : 0)
        }
    }

    /// How far was walked in one month of a year.
    struct MonthDistance: Equatable, Sendable {
        let month: Month
        /// The month's span in the calendar, which is what names it: one
        /// number can be two months, as a Hebrew year's 7 is Adar, or Adar II
        /// in a leap year.
        let interval: DateInterval
        var distanceMeters: Double
    }

    /// One column of the chart: a month, and what was walked in it in each of
    /// the two years that has it.
    struct MonthColumn: Equatable, Sendable {
        let month: Month
        let thisYear: MonthDistance?
        let lastYear: MonthDistance?
    }

    let year: Int
    let thisYear: Figures
    let lastYear: Figures
    let allTime: Figures
    /// Distance by month, in the calendar's order: every month the year has,
    /// whether or not anything was walked in it — see the file header.
    let monthsThisYear: [MonthDistance]
    let monthsLastYear: [MonthDistance]
    let longest: LibraryRecordCandidate?
    let highest: LibraryRecordCandidate?
    let steepest: LibraryRecordCandidate?

    /// How long a hike has to be before its gradient is a record rather than
    /// a steep few hundred metres of a driveway. An outing that climbed
    /// nothing is never the steepest, however long.
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
            // An outing with no climb was along a line its trail has been
            // redrawn from since, so the trail's highest point is the new
            // line's and says nothing about where that walk went.
            return LibraryRecordCandidate(
                hikeID: hike.hikeID,
                title: hike.title,
                distanceMeters: outing.distanceMeters,
                walkedMeters: outing.walkedMeters,
                climbMeters: hike.climbMeters == nil ? nil : outing.climbMeters,
                highestMeters: outing.climbMeters == nil ? nil : hike.highestMeters
            )
        }
        longest = candidates.max { $0.distanceMeters < $1.distanceMeters }
        highest = candidates.filter { $0.highestMeters != nil }
            .max { ($0.highestMeters ?? 0) < ($1.highestMeters ?? 0) }
        steepest = candidates
            .filter { $0.distanceMeters >= Self.steepestMinimumMeters && ($0.climbMeters ?? 0) > 0 }
            .max { $0.gradient < $1.gradient }
    }

    /// The chart's columns: every month either year has, in order, with each
    /// year's distance in it, or `nil` for a year without that month — a
    /// common Hebrew year has no Adar I to stand beside a leap year's.
    var monthColumns: [MonthColumn] {
        let months = Set(monthsThisYear.map(\.month)).union(monthsLastYear.map(\.month)).sorted()
        return months.map { month in
            MonthColumn(
                month: month,
                thisYear: monthsThisYear.first { $0.month == month },
                lastYear: monthsLastYear.first { $0.month == month }
            )
        }
    }

    /// Every outing in the library, by the rules the file header gives.
    static func outings(hikes: [LibraryHikeFacts], walks: [LibraryWalkFacts]) -> [LibraryOuting] {
        let counted = hikes.filter { $0.hasClock && !$0.isFromCommunity }
        let clocks = counted.compactMap(\.clock)
        let clocked = counted.map { hike in
            LibraryOuting(
                hikeID: hike.hikeID,
                date: hike.date,
                distanceMeters: hike.distanceMeters,
                walkedMeters: hike.distanceMeters,
                climbMeters: hike.climbMeters ?? 0,
                movingSeconds: hike.movingSeconds ?? 0,
                isWalk: false
            )
        }
        let followed = walks.compactMap { walk -> LibraryOuting? in
            guard !walk.isRecordingsOwn else { return nil }
            let share = unrecordedShare(of: walk, clocks: clocks)
            guard share > 0 else { return nil }
            return LibraryOuting(
                hikeID: walk.hikeID,
                date: walk.startedAt,
                distanceMeters: walk.coveredMeters * share,
                walkedMeters: walk.walkedMeters * share,
                climbMeters: walk.trailHasChanged ? nil : walk.climbMeters * share,
                movingSeconds: walk.activeSeconds * share,
                isWalk: true
            )
        }
        return clocked + followed
    }

    /// The fraction of `walk`'s time no clock in `clocks` covers, from 0 to 1.
    /// Overlapping clocks are merged first, so two recordings over the same
    /// minutes take those minutes out once.
    private static func unrecordedShare(of walk: LibraryWalkFacts, clocks: [DateInterval]) -> Double {
        let length = walk.endedAt.timeIntervalSince(walk.startedAt)
        guard length > 0 else { return 1 }
        let overlaps = clocks.compactMap { clock -> (start: Date, end: Date)? in
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
        return max(0, 1 - recorded / length)
    }

    private static func byID(_ hikes: [LibraryHikeFacts]) -> [UUID: LibraryHikeFacts] {
        hikes.keyed(by: \.hikeID, resolvingConflictsWith: { _, first, _ in first })
    }

    /// `year`'s months in `calendar`, each with the distance of the outings in
    /// it. The months are walked from the year's first day to its last, so a
    /// month nothing was walked in still has its bar.
    private static func months(of outings: [LibraryOuting], in year: Int, calendar: Calendar) -> [MonthDistance] {
        var months: [MonthDistance] = []
        if let first = calendar.date(from: DateComponents(year: year)),
           let span = calendar.dateInterval(of: .year, for: first) {
            var start = span.start
            while start < span.end, let interval = calendar.dateInterval(of: .month, for: start), interval.end > start {
                let month = month(of: start, in: calendar)
                months.append(MonthDistance(month: month, interval: interval, distanceMeters: 0))
                start = interval.end
            }
        }
        for outing in outings where calendar.component(.year, from: outing.date) == year {
            let month = month(of: outing.date, in: calendar)
            if let index = months.firstIndex(where: { $0.month == month }) {
                months[index].distanceMeters += outing.distanceMeters
            } else if let interval = calendar.dateInterval(of: .month, for: outing.date) {
                // A month the walk above did not reach is still the year's,
                // and an outing the year counts is never left out of its bars.
                months.append(MonthDistance(month: month, interval: interval, distanceMeters: outing.distanceMeters))
                months.sort { $0.month < $1.month }
            }
        }
        return months
    }

    private static func month(of date: Date, in calendar: Calendar) -> Month {
        let parts = calendar.dateComponents([.month, .isLeapMonth], from: date)
        return Month(number: parts.month ?? 0, isLeap: parts.isLeapMonth ?? false)
    }
}

// MARK: - Reading the library

nonisolated enum LibraryTotalsSweep {
    /// The two fetches the sweep makes. The app only ever uses ``store``; the
    /// seam is there so a test can make either one fail.
    ///
    /// The intents' read of the finished hikes makes the first of them through
    /// here too — see `HikeIntentCoordinator.finishedHikes()` — so a failing
    /// `hikes` fails that read as well, and a suite can see which thread it ran
    /// on.
    struct Reads: Sendable {
        var hikes: @Sendable (ModelContext) throws -> [Hike]
        var walks: @Sendable (ModelContext) throws -> [HikeWalk]

        static let store = Self(
            hikes: { try $0.fetch(FetchDescriptor<Hike>()) },
            walks: { try $0.fetch(FetchDescriptor<HikeWalk>()) }
        )
    }

    /// Every hike and walk in `container`, read once in a context of its own
    /// and walked into values. `@concurrent`, so a library as long as a
    /// hiker's walking life is walked off the main actor.
    ///
    /// Throws when either fetch does, rather than summing what the other one
    /// returned: a library that could not be read is not an empty one, and a
    /// walk read without its hikes loses the clocks that keep an afternoon
    /// from counting twice.
    @concurrent
    static func read(
        from container: ModelContainer,
        using reads: Reads = .store
    ) async throws -> (hikes: [LibraryHikeFacts], walks: [LibraryWalkFacts]) {
        assertOffMainThread("Summing the library walks every route, and must stay off the main thread")
        let context = ModelContext(container)
        let hikes = try reads.hikes(context)
        let walks = try reads.walks(context)
        // The line each walked trail draws now, to tell a walk along it from
        // one along a line the trail has been redrawn from since. Hashed from
        // the route its figures are measured from, so a route is read once.
        let walkedIDs = Set(walks.map(\.hikeID))
        // The route itself only of a followed trail, since a followed walk is
        // the only one ``walkFacts(_:revisions:routes:)`` climbs. Every saved
        // recording has a walk of its own, so keeping the route of every
        // walked trail kept every recording's at once.
        let followedIDs = Set(walks.filter { $0.endReason != .recorded }.map(\.hikeID))
        var revisions: [UUID: String] = [:]
        var routes: [UUID: [RouteCoordinate]] = [:]
        let hikeFacts = hikes.compactMap { hike -> LibraryHikeFacts? in
            // A recording still being drawn is not a walk yet.
            guard !hike.isRecording else { return nil }
            let route = hike.route
            if walkedIDs.contains(hike.id), revisions[hike.id] == nil {
                revisions[hike.id] = TrailWalkRecord.routeRevision(of: route)
                if followedIDs.contains(hike.id) { routes[hike.id] = route }
            }
            let statistics = HikeRouteStatistics(distanceMeters: hike.distanceMeters, route: route)
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
        return (hikeFacts, walkFacts(walks, revisions: revisions, routes: routes))
    }

    /// `walks` as values, each climbed along the line its trail draws now
    /// when that is the line it was walked on — see the file header.
    ///
    /// A trail's profile is built once, on its first walk that needs it, and
    /// never for a recording's own walk, which the totals leave out: most
    /// hikes have one, and few have been followed.
    private static func walkFacts(
        _ walks: [HikeWalk],
        revisions: [UUID: String],
        routes: [UUID: [RouteCoordinate]]
    ) -> [LibraryWalkFacts] {
        var profiles: [UUID: RouteProfile] = [:]
        return walks.map { walk in
            let coverage = walk.coverage
            let isRecordingsOwn = walk.endReason == .recorded
            let trailHasChanged = revisions[walk.hikeID].map { !walk.isAlong(revision: $0) } ?? false
            var climb = 0.0
            if !isRecordingsOwn, !trailHasChanged, let route = routes[walk.hikeID] {
                let profile = profiles[walk.hikeID] ?? RouteProfile(route: route)
                profiles[walk.hikeID] = profile
                climb = profile.climb(walking: coverage)?.gainMeters ?? 0
            }
            return LibraryWalkFacts(
                hikeID: walk.hikeID,
                startedAt: walk.startedAt,
                endedAt: walk.endedAt,
                coveredMeters: coverage.coveredMeters,
                walkedMeters: coverage.walkedMeters,
                activeSeconds: walk.activeSeconds,
                climbMeters: climb,
                isRecordingsOwn: isRecordingsOwn,
                trailHasChanged: trailHasChanged
            )
        }
    }
}
