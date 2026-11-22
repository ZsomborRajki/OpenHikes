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

    /// The ends of a line that were not walked, by how far the hiker was
    /// carried over each — see ``RouteCarriedEnds``. Kept so the hike's own
    /// screen can say so without reading the line.
    struct NotOnFoot: Codable, Equatable, Sendable {
        var leadingMeters: Double?
        var trailingMeters: Double?
        /// Whether the hiker has looked: saved an edit, or said the line is
        /// right as it is. A ride on a cable car is a line that is right.
        var isChecked = false

        var totalMeters: Double { (leadingMeters ?? 0) + (trailingMeters ?? 0) }

        init?(_ ends: RouteCarriedEnds, isChecked: Bool = false) {
            guard !ends.isEmpty else { return nil }
            leadingMeters = ends.leading?.carriedMeters
            trailingMeters = ends.trailing?.carriedMeters
            self.isChecked = isChecked
        }
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
        /// ``RouteEdit/notOnFoot`` before the first edit.
        var notOnFoot: NotOnFoot?
    }

    /// The hike before its first edit, or `nil` once it has been reverted:
    /// there is an original to go back to exactly while this is set.
    var original: Original?
    /// The hike's ``Hike/communitySubmissionID`` when its line was last
    /// changed, by an edit or by a revert, or `nil` for a line never changed
    /// while shared.
    var editedUnderSubmissionID: String?
    /// What a recording's line was put together from at Stop, with the
    /// stretches the hiker can still answer for, or `nil` for a hike trail
    /// matching never touched — see ``RouteAssembly``. Written by the save
    /// that makes the hike, so it is here on a hike nobody has edited.
    var assembly: RouteAssembly?
    /// The part of the whole line that is kept, in metres along it, or `nil`
    /// for all of it. The whole line is the one ``assembly`` rebuilds from
    /// the line as it was saved, or that line itself: a trim is a pair of
    /// cuts on it, so *Edit Route* can move them back out as well as in.
    var trim: ClosedRange<Double>?
    /// ``RouteTrim/EndPauses`` of ``trim``, as its raw value, or `nil` for
    /// none: the pauses standing on the whole line's own ends that the cuts
    /// take off, which no distance along the line can say. Read through
    /// ``endPausesTakenOff``.
    var trimEndPauses: Int?
    /// The ends of the line as it is drawn now that were not walked.
    var notOnFoot: NotOnFoot?

    /// Whether anything is left to keep: a reverted hike that was never
    /// shared, and had nothing to check, keeps no column at all.
    var isEmpty: Bool {
        original == nil && editedUnderSubmissionID == nil && assembly == nil && trim == nil && notOnFoot == nil
    }

    /// The pauses on the whole line's ends that ``trim`` takes off.
    var endPausesTakenOff: RouteTrim.EndPauses {
        get { RouteTrim.EndPauses(rawValue: trimEndPauses ?? 0) }
        set { trimEndPauses = newValue.isEmpty ? nil : newValue.rawValue }
    }

    /// How many stretches trail matching left for the hiker to look at,
    /// and has not been looked at yet. What the hike's screen counts — see
    /// ``HikeRouteCheckNotice``.
    var uncheckedCount: Int { assembly?.uncheckedCount ?? 0 }

    /// The ends that were not walked, while the hiker has not looked at them.
    var uncheckedNotOnFoot: NotOnFoot? {
        notOnFoot.flatMap { $0.isChecked ? nil : $0 }
    }

    /// Whether the hike's screen has anything to say about the line.
    var isOwedALook: Bool { uncheckedCount > 0 || uncheckedNotOnFoot != nil }

    /// Everything looked at, and nothing else changed.
    var looked: Self {
        var seen = self
        if var pieces = seen.assembly {
            for index in pieces.checks.indices { pieces.checks[index].isChecked = true }
            seen.assembly = pieces
        }
        seen.notOnFoot?.isChecked = true
        return seen
    }
}

nonisolated extension RouteEdit {
    /// Spelled out rather than refused: a height a receiver reported as not
    /// a number, on a point a stretch's answer keeps, would otherwise make
    /// the whole record unwritable, and a hike edited with no record has its
    /// original written over by the next edit.
    private static let nonFinite = (positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: nonFinite.positiveInfinity,
            negativeInfinity: nonFinite.negativeInfinity,
            nan: nonFinite.nan
        )
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonFinite.positiveInfinity,
            negativeInfinity: nonFinite.negativeInfinity,
            nan: nonFinite.nan
        )
        return decoder
    }
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
    /// as `nil`, as ``drawnRoute`` does, and is never taken for a hike with
    /// no record: ``hasUnreadableRouteEdit``.
    var routeEdit: RouteEdit? {
        get {
            guard let routeEditData else { return nil }
            return try? RouteEdit.decoder().decode(RouteEdit.self, from: routeEditData)
        }
        set {
            routeEditData = newValue.flatMap { $0.isEmpty ? nil : try? RouteEdit.encoder().encode($0) }
        }
    }

    /// Whether the hike has an edit record that does not read: one a later
    /// build wrote on the hiker's other device. Taken for a hike never
    /// edited, the next save would write its own line over the original.
    var hasUnreadableRouteEdit: Bool {
        routeEditData != nil && routeEdit == nil
    }

    /// Whether *Edit Route* has changed this hike's line and kept the one it
    /// had, which is when *Revert to Original* has something to put back.
    var hasOriginalRoute: Bool { routeEdit?.original != nil }

    /// The walk this hike's recording wrote for itself, if it was recorded.
    var recordedWalk: HikeWalk? {
        walks?.first { $0.endReason == .recorded }
    }
}
