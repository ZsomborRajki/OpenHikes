//
//  SharedTrailSnapshot+Pauses.swift
//  OpenHikesShared
//
//  The widget's line, decimated without losing its pauses.
//
//  A plain stride (``decimatedIndices(count:maxPoints:)``) drops points by
//  index, so it can drop either end of a paused leg, and then the leg it
//  draws is a drive folded into a stretch with walking in it: neither a pause
//  nor trail. The watch's packager keeps both ends of the pauses it sends for
//  that reason, as many as ``WatchTrailPackage/pauseBudget`` (#1023).
//  This keeps both ends of as many pauses as ``SharedTrailSnapshot/pauseEndBudget``
//  allows, longest first, and spends the rest of the widget's points on the
//  stride over the other points, so a line past `maxPoints` comes to exactly
//  `maxPoints`, as the watch's comes to its budget.
//

public extension SharedTrailSnapshot {
    /// How many of the widget's points may go on the ends of paused legs.
    ///
    /// A third of the line: thirty separate pauses, or more where they are
    /// adjacent and share their ends, which is far more than a hiker presses
    /// Pause on one walk. A GPX file can break into hundreds of segments; its
    /// shortest gaps then decimate into the line like any other leg, which at
    /// a widget's size is a hairline.
    static let pauseEndBudget = 60

    /// The line cut at its pauses — see ``TrailRuns``.
    var runs: TrailRuns {
        TrailRuns(pointCount: polyline.count, pauseIndices: pauseIndices)
    }

    /// The widget's line for `route`: at most `maxPoints` points, with both
    /// ends of every paused leg kept while `pauseEndBudget` lasts, and the
    /// indices of the kept points a kept pause arrives at.
    ///
    /// Longest pauses first, measured as the crow flies, because a long one
    /// is the drive that would otherwise read as a trail across the whole
    /// widget; a short one is a hairline at this size whichever way it is
    /// drawn. Equal lengths go in route order.
    ///
    /// - Parameters:
    ///   - runs: `route` cut at its pauses — on the phone,
    ///     `[RouteCoordinate].trailRuns`.
    static func line<Element>(
        of route: [Element],
        cutAt runs: TrailRuns,
        maxPoints: Int = 180,
        pauseEndBudget: Int = pauseEndBudget,
        coordinate: (Element) -> CodableCoordinate
    ) -> (polyline: [CodableCoordinate], pauseIndices: [Int]) {
        assert(runs.pointCount == route.count, "the runs of another line")
        let kept = keptIndices(
            count: route.count,
            maxPoints: maxPoints,
            pausedLegs: pausedLegsByLength(runs.pausedLegs, in: route, coordinate: coordinate),
            pauseEndBudget: pauseEndBudget
        )
        // Only a kept leg that is the pause alone, both ends next to each
        // other on the route: a leg the stride drew across a pause it could
        // not afford also has walking in it, and is drawn as the line.
        let paused = Set(runs.pausedLegs)
        let pauseIndices = kept.indices.dropFirst().filter { position in
            kept[position] == kept[position - 1] + 1 && paused.contains(kept[position - 1])
        }
        return (kept.map { coordinate(route[$0]) }, pauseIndices)
    }

    /// Which of `count` points the line keeps: both ends of each of
    /// `pausedLegs`, in the order given, until `pauseEndBudget` points are
    /// spent, and the stride over the points that are not one of those ends.
    /// All of them for a route that fits in `maxPoints`, and exactly
    /// `maxPoints` for a longer one: the fill is
    /// ``decimatedIndices(count:maxPoints:keeping:)``, the watch's and the
    /// elevation request's too, and only the choice of ends is the widget's.
    ///
    /// Internal so the bound can be tested without building a route.
    internal static func keptIndices(
        count: Int,
        maxPoints: Int,
        pausedLegs: [Int],
        pauseEndBudget: Int
    ) -> [Int] {
        guard count > maxPoints else { return Array(0..<max(0, count)) }
        // Two points are left for the stride at least, so the route's first
        // and last points are always kept, as the stride's own or as an end.
        let budget = min(pauseEndBudget, maxPoints - 2)
        var ends = Set<Int>()
        for leg in pausedLegs where leg >= 0 && leg + 1 < count {
            let added = [leg, leg + 1].filter { !ends.contains($0) }
            guard ends.count + added.count <= budget else { continue }
            ends.formUnion(added)
        }
        return decimatedIndices(count: count, maxPoints: maxPoints, keeping: ends)
    }

    private static func pausedLegsByLength<Element>(
        _ legs: [Int],
        in route: [Element],
        coordinate: (Element) -> CodableCoordinate
    ) -> [Int] {
        let lengths = legs.map { leg in
            let start = coordinate(route[leg]), end = coordinate(route[leg + 1])
            let meters = WatchGeodesy.distanceMeters(
                fromLatitude: start.latitude,
                longitude: start.longitude,
                toLatitude: end.latitude,
                longitude: end.longitude
            )
            // A non-finite coordinate would make the order below inconsistent.
            return meters.isFinite ? meters : 0
        }
        return legs.indices
            .sorted { lengths[$0] != lengths[$1] ? lengths[$0] > lengths[$1] : $0 < $1 }
            .map { legs[$0] }
    }
}
