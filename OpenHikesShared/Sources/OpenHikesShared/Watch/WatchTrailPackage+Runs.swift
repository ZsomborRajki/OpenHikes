//
//  WatchTrailPackage+Runs.swift
//  OpenHikesShared
//
//  Which of a trail's points are trail, and which legs between them are a
//  pause: the one reading of ``WatchTrailPackage/pauseIndices`` that the
//  watch's tracker and its map both take.
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
//  coordinates. The tracker reads ``WatchTrailPackage/pausedLegs`` too, so
//  the leg the map draws as a pause is exactly the leg the tracker refuses —
//  two readings of the same indices could not drift apart, because there is
//  only one.
//

import Foundation

public extension WatchTrailPackage {
    /// The legs a pause opened, in order, each by the index of the point it
    /// leaves: leg `i` runs from `points[i]` to `points[i + 1]`.
    ///
    /// ``pauseIndices`` names the point a recording resumed on, and the leg
    /// *arriving* there is the pause, so each one is shifted back by one. An
    /// index the line cannot hold is dropped rather than trusted — `0` has
    /// nothing before it to have been paused across, and an index past the
    /// last point names a leg that is not there — and one named twice is the
    /// same leg.
    var pausedLegs: [Int] {
        Set(pauseIndices.filter { $0 > 0 && $0 < points.count })
            .map { $0 - 1 }
            .sorted()
    }

    /// The stretches that were walked, in order, as ranges of indices into
    /// ``points``: the line cut at every paused leg.
    ///
    /// Each holds two points or more. A run of one — the point between two
    /// adjacent pauses, or the lone point a trail starts or ends on when its
    /// first or last leg was paused — is a place, not a line, which is
    /// ``isDrawable``'s rule for the whole trail; it stays on the map as the
    /// end of the paused legs either side of it.
    ///
    /// Together with ``pausedLegs`` this covers every leg exactly once, so
    /// nothing the phone sent is left undrawn and nothing is drawn twice.
    var walkedRuns: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        for leg in pausedLegs + [points.count - 1] {
            let end = leg + 1
            if end - start > 1 { runs.append(start..<end) }
            start = end
        }
        return runs
    }
}
