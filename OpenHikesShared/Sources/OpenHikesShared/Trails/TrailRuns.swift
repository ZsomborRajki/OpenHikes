//
//  TrailRuns.swift
//  OpenHikesShared
//
//  Which legs of a line are trail, and which are a pause: the one reading of a
//  line's pause indices that every surface drawing a trail takes, so they
//  break the line in the same places.
//
//  A pause is not trail (#962). The leg arriving at a pause index is a drive
//  or a lift between two recorded pieces, or the jump between two GPX
//  `<trkseg>`s. Each map draws the walked runs as trail and the paused
//  stretches between them faded and dotted, never as the solid line:
//
//  - the watch's map, through ``WatchTrailPackage``'s forwarding properties
//    (#997), whose tracker reads the same ``pausedLegs``
//  - the trail widget, through ``TrailStroke``'s pieces, from
//    ``SharedTrailSnapshot/pauseIndices`` (#1034)
//  - the phone's map, which cuts its route line at the walked runs (#1034)
//
//  Moved here from `WatchTrailPackage+Runs.swift` when the widget and the
//  phone came to need it, so the three cannot disagree about where a line
//  breaks. Plain indices and the standard library only, because this package
//  has no dependencies (see *Layout and targets* in AGENTS.md).
//

/// A line of `pointCount` points cut at its pauses.
public struct TrailRuns: Sendable, Equatable {
    /// The legs a pause opened, in order, each by the index of the point it
    /// leaves: leg `i` runs from point `i` to point `i + 1`.
    ///
    /// A pause index names the point a recording resumed on, and the leg
    /// *arriving* there is the pause, so each one is shifted back by one. An
    /// index the line cannot hold is dropped rather than trusted — `0` has
    /// nothing before it to have been paused across, and an index past the
    /// last point names a leg that is not there — and one named twice is the
    /// same leg.
    public let pausedLegs: [Int]

    /// The stretches that were walked, in order, as ranges of point indices:
    /// the line cut at every paused leg.
    ///
    /// Each holds two points or more. A run of one — the point between two
    /// adjacent pauses, or the lone point a line starts or ends on when its
    /// first or last leg was paused — is a place, not a line; it stays drawn
    /// inside the paused stretch that passes through it.
    ///
    /// Together with ``pausedStretches`` this covers every leg exactly once,
    /// so nothing is left undrawn and nothing is drawn twice.
    public let walkedRuns: [Range<Int>]

    /// The stretches nobody walked, in order, as ranges of point indices:
    /// each run of adjacent ``pausedLegs``, from the point the first leaves to
    /// the point the last arrives at.
    ///
    /// Adjacent legs are one stretch rather than one each because each is a
    /// line a map has to draw: a GPX file whose segments hold a point apiece
    /// is paused on every leg, and drawn leg by leg it would be as many lines
    /// as it has points. Joined, it is one.
    public let pausedStretches: [Range<Int>]

    /// - Parameters:
    ///   - pointCount: how many points the line has.
    ///   - pauseIndices: the indices of the points a pause arrives at, the
    ///     convention ``WatchTrailPackage/pauseIndices`` and the phone's
    ///     `RouteBoundary` keep.
    public init(pointCount: Int, pauseIndices: some Sequence<Int>) {
        let legs = Set(pauseIndices.filter { $0 > 0 && $0 < pointCount })
            .map { $0 - 1 }
            .sorted()
        pausedLegs = legs
        walkedRuns = Self.walkedRuns(pointCount: pointCount, pausedLegs: legs)
        pausedStretches = Self.pausedStretches(pausedLegs: legs)
    }

    /// Whether any leg is paused: `false` is a line drawn as one run.
    public var isPaused: Bool { !pausedLegs.isEmpty }

    private static func walkedRuns(pointCount: Int, pausedLegs: [Int]) -> [Range<Int>] {
        guard pointCount > 1 else { return [] }
        var runs: [Range<Int>] = []
        var start = 0
        for leg in pausedLegs + [pointCount - 1] {
            let end = leg + 1
            if end - start > 1 { runs.append(start..<end) }
            start = end
        }
        return runs
    }

    private static func pausedStretches(pausedLegs: [Int]) -> [Range<Int>] {
        var stretches: [Range<Int>] = []
        for leg in pausedLegs {
            if let last = stretches.last, last.upperBound == leg + 1 {
                stretches[stretches.count - 1] = last.lowerBound..<(leg + 2)
            } else {
                stretches.append(leg..<(leg + 2))
            }
        }
        return stretches
    }
}
