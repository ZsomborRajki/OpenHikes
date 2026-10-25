//
//  WatchTrailPackage+Budget.swift
//  OpenHikesShared
//
//  Which of a route's points cross to the watch, and which of its pauses
//  cross with them.
//
//  ## Why pauses need a budget of their own
//
//  The watch can refuse a paused leg only if the leg is the pause alone (#962),
//  so the phone keeps both ends of every pause it sends, whatever the stride
//  would have dropped. Two points a pause is cheap for a recording, where the
//  count is how often a hiker reached for the button. It is not cheap for an
//  import: a GPX file's every `<trkseg>` after the first opens a pause, and
//  nothing bounds how many segments a file holds. A 2,000-segment file kept
//  4,648 points against the 800 the transfer is sized for, and its map drew
//  about 6,000 polylines, three for every walked run and paused stretch (#1023).
//
//  So at most ``WatchTrailPackage/pauseBudget`` pauses cross, and their ends
//  come out of ``WatchTrailPackage/pointBudget`` rather than on top of it: a
//  route that fits crosses whole, a longer one crosses as exactly the budget,
//  and the map never draws more than three lines a kept pause plus two.
//
//  ## Which pauses are kept
//
//  The longest breaks. A break of a kilometre is a drive or a lift, the thing
//  the dotted line exists to say a hiker must not follow. A break of a few
//  metres is a GPS dropout or a file split on the walk itself, and folding it
//  into the line means the watch measures and matches across a gap the hiker
//  most likely walked: the smaller error of the two, and drawn as trail, which
//  near enough it is. A folded pause leaves no trace in the package; whether
//  its two ends cross is the stride's business again.
//
//  ## Why here rather than on the phone
//
//  The watch has no test bundle and the phone's half is the expensive one to
//  test, so the arithmetic is here under `swift test`. The phone only hands
//  over the route cut at its pauses, ``TrailRuns``, and measures each break
//  (`WatchTrailPackaging`).
//

import Foundation

public extension WatchTrailPackage {
    /// How many of a route's pauses cross to the watch. See
    /// `WatchTrailPackage+Budget.swift` for why there is a cap and which
    /// pauses it keeps.
    ///
    /// Fifty pauses cost at most a hundred of the ``pointBudget``'s points,
    /// and at most 152 polylines on the watch's map. A recording rarely comes
    /// near it; a GPX file split at every dropout can pass it many times over.
    static let pauseBudget = 50

    /// The points of a route that cross, and which of them a recording
    /// resumed on.
    struct KeptPoints: Sendable, Equatable {
        /// Indices into the route, ascending: all of them for a route that
        /// fits in ``pointBudget``, and exactly ``pointBudget`` for a longer
        /// one.
        public var routeIndices: [Int]
        /// Indices into ``routeIndices`` of the points a kept pause resumed
        /// on: what ``WatchTrailPackage/pauseIndices`` carries. The point
        /// before each is the route point before it, so each names exactly
        /// one leg of the route.
        public var pauseIndices: [Int]
    }

    /// Which points of a route cross, given the route cut at its pauses.
    ///
    /// The kept pauses are the ``pauseBudget`` with the longest gaps, ties
    /// going to the earlier one so that the same route always packages the
    /// same way. Both ends of each are kept. The rest of ``pointBudget`` is
    /// the same stride the widget uses, ``decimatedIndices(count:maxPoints:)``,
    /// taken over the points that are not one of those ends. A route that
    /// fits therefore crosses whole, and a longer one as exactly
    /// ``pointBudget`` points, its first and last among them.
    ///
    /// A pause the route cannot hold is already gone: ``TrailRuns`` drops one
    /// at `0`, with nothing before it, or past the end, and counts one named
    /// twice once.
    ///
    /// - Parameters:
    ///   - runs: the route cut at its pauses.
    ///   - gapMeters: the length of the break across paused leg `leg`, on the
    ///     ground. Asked only when there are more pauses than cross.
    static func keptPoints(
        of runs: TrailRuns,
        gapMeters: (_ leg: Int) -> Double,
        pointBudget: Int = Self.pointBudget,
        pauseBudget: Int = Self.pauseBudget
    ) -> KeptPoints {
        // A pause costs at most two points, and the stride needs two of its
        // own for the ends of the line.
        let affordable = max(0, min(pauseBudget, (pointBudget - 2) / 2))
        let keptLegs: [Int]
        if runs.pausedLegs.count <= affordable {
            keptLegs = runs.pausedLegs
        } else {
            // A non-finite gap would make the order below inconsistent, and a
            // break nobody can measure is no reason to keep it over one that
            // can be.
            let gaps = runs.pausedLegs.map { leg in
                let gap = gapMeters(leg)
                return gap.isFinite ? gap : 0
            }
            keptLegs = runs.pausedLegs.indices
                .sorted { gaps[$0] != gaps[$1] ? gaps[$0] > gaps[$1] : $0 < $1 }
                .prefix(affordable)
                .map { runs.pausedLegs[$0] }
        }
        let ends = Set(keptLegs.flatMap { [$0, $0 + 1] })
        // The point each kept pause arrives at, which is what the package's
        // pause indices name.
        let resumes = Set(keptLegs.map { $0 + 1 })
        // The stride never lands on an end, so none of its points is spent on
        // one that is kept anyway. Taken over the whole route, it lost a point
        // to every end it happened to keep: a route of 800 points with a pause
        // every 16 crossed as 714, and a 900-point file of 100 segments as
        // 700. The route's first and last points are kept either way, as the
        // stride's own or as an end.
        let others = (0..<runs.pointCount).filter { !ends.contains($0) }
        let strided = decimatedIndices(count: others.count, maxPoints: max(2, pointBudget - ends.count))
        let routeIndices = ends.union(strided.map { others[$0] }).sorted()
        let pauseIndices = routeIndices.indices.filter { resumes.contains(routeIndices[$0]) }
        return KeptPoints(routeIndices: routeIndices, pauseIndices: pauseIndices)
    }
}
