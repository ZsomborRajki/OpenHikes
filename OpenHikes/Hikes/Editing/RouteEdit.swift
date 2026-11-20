//
//  RouteEdit.swift
//  OpenHikes
//
//  What an edited hike was before its line was edited, kept on the hike so
//  *Revert to Original* can put all of it back.
//
//  The line itself is ``Hike/originalRoute``. This is what goes back with it:
//  the figures a trim rewrites because they are about the line, and which the
//  line alone cannot give again. A recording's distance leaves out the
//  windows it stood still in, so it is not its line's length; its own walk
//  ends when the hiker pressed Stop, which can be long after its last point.
//
//  ## On the hike, and synced
//
//  For the reason ``DrawnRoute`` is: an edit made on the phone should be
//  revertible on the iPad, and one `Data` column of JSON crosses CloudKit as
//  a single field that a later addition costs no schema change. A drawn
//  trail never carries one, because the maker edits it by its stops.
//
//  ## A shared hike that was edited
//
//  A submission is write-once, so an edit changes the hike and not the
//  listing, exactly as the maker's does. ``editedUnderSubmissionID`` is the
//  note ``DrawnRoute/editedUnderSubmissionID`` keeps for a drawn trail, for
//  every other hike: which submission the hike had when its line was last
//  edited, so the share menu can say the shared copy shows the old route.
//

import Foundation
import OpenHikesData

nonisolated struct RouteEdit: Codable, Equatable, Sendable {
    /// The recording's own walk, as Stop wrote it — see ``HikeWalk/recorded(_:prepared:)``.
    struct RecordedWalk: Codable, Equatable, Sendable {
        var startedAt: Date
        var endedAt: Date
        var activeSeconds: Double
        var coveredIntervals: [Double]
        var furthestDistanceMeters: Double
        var routeDistanceMeters: Double
        var routeRevision: String?
    }

    /// What goes back with ``Hike/originalRoute``.
    struct Original: Codable, Equatable, Sendable {
        /// ``Hike/distanceMeters`` before the first edit.
        var distanceMeters: Double
        /// ``Hike/date`` before the first edit, which a trimmed start moves.
        var date: Date
        /// The recording's own walk before the first edit, or `nil` for a
        /// hike with none: an import, or a recording too short for one.
        var recordedWalk: RecordedWalk?
    }

    /// The hike before its first edit, or `nil` once it has been reverted:
    /// there is an original to go back to exactly while this is set.
    var original: Original?
    /// The hike's ``Hike/communitySubmissionID`` when its line was last
    /// changed, by an edit or by a revert, or `nil` for a line never changed
    /// while shared.
    var editedUnderSubmissionID: String?

    /// Whether anything is left to keep: a reverted hike that was never
    /// shared keeps no column at all.
    var isEmpty: Bool { original == nil && editedUnderSubmissionID == nil }
}

extension RouteEdit.RecordedWalk {
    @MainActor
    init(_ walk: HikeWalk) {
        startedAt = walk.startedAt
        endedAt = walk.endedAt
        activeSeconds = walk.activeSeconds
        coveredIntervals = walk.coveredIntervals
        furthestDistanceMeters = walk.furthestDistanceMeters
        routeDistanceMeters = walk.routeDistanceMeters
        routeRevision = walk.routeRevision
    }

    @MainActor
    func write(to walk: HikeWalk) {
        walk.startedAt = startedAt
        walk.endedAt = endedAt
        walk.activeSeconds = activeSeconds
        walk.coveredIntervals = coveredIntervals
        walk.furthestDistanceMeters = furthestDistanceMeters
        walk.routeDistanceMeters = routeDistanceMeters
        walk.routeRevision = routeRevision
    }
}

extension Hike {
    /// What this hike was before its line was edited, or `nil` for a line
    /// never edited — see ``RouteEdit``. A value that fails to decode reads
    /// as `nil`, as ``drawnRoute`` does.
    var routeEdit: RouteEdit? {
        get {
            guard let routeEditData else { return nil }
            return try? JSONDecoder().decode(RouteEdit.self, from: routeEditData)
        }
        set {
            routeEditData = newValue.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }
        }
    }

    /// Whether *Edit Route* has changed this hike's line and kept the one it
    /// had, which is when *Revert to Original* has something to put back.
    var hasOriginalRoute: Bool { routeEdit?.original != nil }

    /// The walk this hike's recording wrote for itself, if it was recorded.
    var recordedWalk: HikeWalk? {
        walks?.first { $0.endReason == .recorded }
    }
}
