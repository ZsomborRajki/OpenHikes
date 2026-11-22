//
//  ActivityEnding.swift
//  OpenHikes
//
//  What a Stop or an End came to, for the view that owns the sheet's path.
//
//  A recording is stopped, and a walk ended, from two places: the bar of its
//  own screen, and the capsule on the map that stands in for that bar on
//  every other screen — see ``MapActivityCapsule``. Neither owns the sheet's
//  navigation stack, and the capsule is not in the view tree at all, so the
//  question each asks ends in a message rather than a closure: a saved
//  recording opens its hike, a discarded one takes its screen away, and a
//  walk that was kept opens its summary. ``OpenHikesView`` reads them from
//  its own task, as it reads the widget's links — see ``EventFeed`` for why a
//  navigation asked for from outside a tap goes that way.
//
//  Identifiers rather than models, because a message crosses into a task
//  and a `@Model` is not `Sendable`. The reader looks each one up in its own
//  context, and a row that has gone meanwhile is a message with nothing to
//  open.
//

import Foundation

/// What ending a recording or a walk came to.
nonisolated enum ActivityEnding: Equatable, Sendable {
    /// The recording was thrown away, with its draft when it had one.
    case recordingDiscarded(hikeID: UUID?)
    /// The recording was saved as this hike.
    case recordingSaved(hikeID: UUID)
    /// The walk along this hike was ended and kept as this walk.
    case walkKept(hikeID: UUID, walkID: UUID)
}
