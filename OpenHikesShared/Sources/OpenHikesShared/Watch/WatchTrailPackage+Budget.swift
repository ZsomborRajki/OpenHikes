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
//  So at most ``WatchTrailPackage/pauseBudget`` pauses cross, and the stride
//  takes what their ends leave of ``WatchTrailPackage/pointBudget``: the
//  package never exceeds its budget, and the map never draws more than three
//  lines a kept pause plus two.
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
//  test, so the arithmetic is here under `swift test`. The phone only measures
//  each break and hands over the indices (`WatchTrailPackaging`).
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

    /// A point a route resumed on after a pause, and how far it is from the
    /// point before it: the length of the break, on the ground.
    struct RoutePause: Sendable, Equatable {
        /// The index into the route of the point the pause arrives at.
        public var resumedAt: Int
        public var gapMeters: Double

        public init(resumedAt: Int, gapMeters: Double) {
            self.resumedAt = resumedAt
            self.gapMeters = gapMeters
        }
    }

    /// The points of a route that cross, and which of them a recording
    /// resumed on.
    struct KeptPoints: Sendable, Equatable {
        /// Indices into the route, ascending, never more than ``pointBudget``.
        public var routeIndices: [Int]
        /// Indices into ``routeIndices`` of the points a kept pause resumed
        /// on: what ``WatchTrailPackage/pauseIndices`` carries. The point
        /// before each is the route point before it, so each names exactly
        /// one leg of the route.
        public var pauseIndices: [Int]
    }

    /// Which points of a route of `count` points cross, given its `pauses`.
    ///
    /// The kept pauses are the ``pauseBudget`` with the longest gaps, ties
    /// going to the earlier one so that the same route always packages the
    /// same way. Both ends of each are kept. The rest of ``pointBudget`` is
    /// the same stride the widget uses, ``decimatedIndices(count:maxPoints:)``,
    /// which always keeps the first and last points.
    ///
    /// A pause the route cannot hold — at `0`, with nothing before it, or past
    /// the end — is ignored, and one named twice counts once.
    static func keptPoints(
        count: Int,
        pauses: [RoutePause],
        pointBudget: Int = Self.pointBudget,
        pauseBudget: Int = Self.pauseBudget
    ) -> KeptPoints {
        var seen = Set<Int>()
        let valid = pauses
            .filter { $0.resumedAt > 0 && $0.resumedAt < count && seen.insert($0.resumedAt).inserted }
            // A non-finite gap would make the order below inconsistent, and
            // a break nobody can measure is no reason to keep it over one
            // that can be.
            .map { $0.gapMeters.isFinite ? $0 : RoutePause(resumedAt: $0.resumedAt, gapMeters: 0) }
        // A pause costs at most two points, and the stride needs two of its
        // own for the ends of the line.
        let affordable = max(0, min(pauseBudget, (pointBudget - 2) / 2))
        let kept = valid.count <= affordable ? valid : Array(
            valid
                .sorted { $0.gapMeters != $1.gapMeters ? $0.gapMeters > $1.gapMeters : $0.resumedAt < $1.resumedAt }
                .prefix(affordable)
        )
        let resumes = Set(kept.map(\.resumedAt))
        let ends = Set(resumes.flatMap { [$0 - 1, $0] })
        let strided = decimatedIndices(count: count, maxPoints: max(2, pointBudget - ends.count))
        let routeIndices = ends.union(strided).sorted()
        let pauseIndices = routeIndices.indices.filter { resumes.contains(routeIndices[$0]) }
        return KeptPoints(routeIndices: routeIndices, pauseIndices: pauseIndices)
    }
}
