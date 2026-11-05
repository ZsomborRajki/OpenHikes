//
//  TrailWalkEnd.swift
//  OpenHikes
//
//  What ``TrailWalkSession`` answers when it is asked to end a walk. Split
//  from the session for length: it is the session's vocabulary, not a step
//  in running a walk.
//

import OpenHikesData

/// What ending a walk came to.
///
/// Three answers rather than an optional row, because the third one is not a
/// missing row: a store that refuses the commit leaves the walk *under way*,
/// and a caller that could not tell it from a walk too short to keep would
/// take the controls off screen for a walk that is still running.
enum TrailWalkEnd {
    /// The walk ended with nothing to keep — under
    /// ``TrailWalkPolicy/minimumCoverageMeters``, or along a hike that has
    /// gone away — or there was no walk to end.
    case discarded
    /// The walk ended and became this row.
    case kept(HikeWalk)
    /// The store refused the commit. Nothing was cleared and nothing was
    /// written: the walk is still under way and can be ended again.
    case refused
}

extension TrailWalkEnd {
    /// The row the walk became, if it became one. For a caller that has
    /// nothing to say about a refusal; the one that does switches instead.
    var walk: HikeWalk? {
        guard case let .kept(walk) = self else { return nil }
        return walk
    }
}
