//
//  WatchTrailPackage+Runs.swift
//  OpenHikesShared
//
//  Which of a trail's points are trail, and which legs between them are a
//  pause: ``TrailRuns`` over ``WatchTrailPackage/pauseIndices``, the one
//  reading that the watch's tracker and its map both take.
//
//  ## Why the map needs it
//
//  A package is one array of points, and a pause is not trail (#962): the leg
//  arriving at each pause index is a drive or a lift between two recorded
//  pieces, or the jump between two GPX `<trkseg>`s. ``WatchRouteTracker``
//  gives that leg no length and never matches onto it. The map drew the whole
//  array as one solid line anyway, so the transfer looked exactly like the
//  trail the figures measure along — the one stretch on the screen a hiker
//  must not follow, drawn as though they should (#997).
//
//  ## Why here rather than on the watch
//
//  The watch has no test bundle, so the decision is made here, under
//  `swift test`, and `TrailMapScreen` only turns these indices into
//  coordinates. The map's runs and stretches are cut at
//  ``WatchTrailPackage/pausedLegs``, and the tracker reads the same property,
//  so the leg the map draws as a pause is exactly the leg the tracker refuses
//  — two readings of the same indices could not drift apart, because there
//  is only one. ``TrailRuns`` holds it, because the trail widget and the
//  phone's map break their lines by the same rule (#1034).
//

public extension WatchTrailPackage {
    /// The line cut at its pauses — see ``TrailRuns``.
    var runs: TrailRuns {
        TrailRuns(pointCount: points.count, pauseIndices: pauseIndices)
    }

    /// The legs a pause opened — ``TrailRuns/pausedLegs``.
    var pausedLegs: [Int] { runs.pausedLegs }

    /// The stretches that were walked — ``TrailRuns/walkedRuns``.
    var walkedRuns: [Range<Int>] { runs.walkedRuns }

    /// The stretches nobody walked — ``TrailRuns/pausedStretches``.
    var pausedStretches: [Range<Int>] { runs.pausedStretches }
}
