//
//  RecordedClocks.swift
//  OpenHikes
//
//  Every counted hike's clock, kept so that *Totals* finds the clocks over a
//  walk's hours without a scan of every clock in the library for each walk,
//  a scan that grew with the square of the library (#1118).
//
//  The clocks are not merged into one union first, as they once were: which
//  of them count against a walk depends on where each one's hike lay
//  (`LibraryTotals`, ``LibraryFootprint``), so a walk has to see them one by
//  one. A watch that records every walk the phone follows makes every walk
//  one that something overlaps, so the search is what each walk costs.
//
//  ## The search
//
//  The clocks are sorted by start. Read as the search that halves a sorted
//  array, that order is a balanced tree, each range's middle clock its root,
//  and each root keeps the latest end of any clock in its range. A range
//  whose latest end is before the walk begins is passed over whole, and no
//  clock after a root that begins once the walk is over is looked at. A walk
//  then costs the depth of the tree for each clock it meets, however long
//  the library is, and however long one clock in it is: a GPX stamped across
//  a year makes the ranges that hold it look as late as it ends, which is
//  one path down the tree, not every clock beside it.
//
//  The clocks come out in order of start, so their union over the walk is
//  summed in the same pass: two recordings over the same minutes take those
//  minutes out of a walk once.
//

import Foundation

nonisolated struct RecordedClocks: Sendable {
    /// One counted hike's clock, and where its line lay over it.
    struct Clock: Equatable, Sendable {
        let interval: DateInterval
        /// See ``LibraryHikeFacts/footprint``.
        let footprint: LibraryFootprint?
    }

    /// In order of start, each longer than an instant.
    private let clocks: [Clock]
    /// For each index, the latest end among the clocks of the range it is
    /// the middle of — see the file header.
    private let latestEnds: [Date]

    init(_ clocks: [Clock]) {
        let sorted = clocks
            .filter { $0.interval.end > $0.interval.start }
            .sorted { $0.interval.start < $1.interval.start }
        var latest = sorted.map(\.interval.end)
        Self.gatherLatestEnds(into: &latest, over: sorted.indices)
        self.clocks = sorted
        latestEnds = latest
    }

    /// How much of `start` to `end` the clocks `counting` keeps cover, each
    /// instant once.
    func seconds(from start: Date, to end: Date, counting counts: (Clock) -> Bool) -> TimeInterval {
        var seconds: TimeInterval = 0
        // How far the clocks summed so far reach: they come in order of
        // start, so whatever of the next one lies before this is summed.
        var reached = start
        visit(from: start, to: end, over: clocks.indices) { clock in
            guard counts(clock) else { return }
            let from = max(reached, clock.interval.start)
            let to = min(end, clock.interval.end)
            guard to > from else { return }
            seconds += to.timeIntervalSince(from)
            reached = to
        }
        return seconds
    }

    /// Hands `body` every clock that covers some of `start` to `end` among
    /// those in `range`, in order of start.
    private func visit(from start: Date, to end: Date, over range: Range<Int>, _ body: (Clock) -> Void) {
        guard !range.isEmpty else { return }
        let middle = Self.middle(of: range)
        // Nothing in the range runs past the walk's start.
        guard latestEnds[middle] > start else { return }
        visit(from: start, to: end, over: range.lowerBound..<middle, body)
        // Nothing from here on begins before the walk ends.
        guard clocks[middle].interval.start < end else { return }
        if clocks[middle].interval.end > start {
            body(clocks[middle])
        }
        visit(from: start, to: end, over: (middle + 1)..<range.upperBound, body)
    }

    /// Sets each middle of `range`'s halving to the latest end in its range,
    /// and returns the latest end in `range`.
    @discardableResult private static func gatherLatestEnds(
        into latestEnds: inout [Date],
        over range: Range<Int>
    ) -> Date? {
        guard !range.isEmpty else { return nil }
        let middle = middle(of: range)
        if let before = gatherLatestEnds(into: &latestEnds, over: range.lowerBound..<middle) {
            latestEnds[middle] = max(latestEnds[middle], before)
        }
        if let after = gatherLatestEnds(into: &latestEnds, over: (middle + 1)..<range.upperBound) {
            latestEnds[middle] = max(latestEnds[middle], after)
        }
        return latestEnds[middle]
    }

    private static func middle(of range: Range<Int>) -> Int {
        range.lowerBound + range.count / 2
    }
}
