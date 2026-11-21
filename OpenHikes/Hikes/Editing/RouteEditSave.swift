//
//  RouteEditSave.swift
//  OpenHikes
//
//  Writing a trimmed line into its hike, and putting the original back.
//
//  **The same row**, for the reason ``TrailDraftSave/update(_:from:openedWith:into:heights:keepingPlaces:save:)``
//  writes into one: every walk, place, photograph, widget pin and publication
//  pointing at the hike still does. What changes is what the line is, and the
//  figures that are about the line.
//
//  ## What a trim rewrites
//
//  - **The line**, through ``Hike/replaceRoute(with:)``, and its length. The
//    hike's distance loses what the cut took rather than being measured
//    again: a recording's distance leaves out the windows it stood still in
//    (`PreparedRecording.distanceMeters`), and nothing saved says where
//    those were.
//  - **The original**, kept by the first edit and never written again — see
//    ``Hike/originalRoute`` and ``RouteEdit``.
//  - **The recording's own walk.** Every other walk along the hike is a
//    record of a walk that happened and is left as it was, as the maker's
//    edit leaves it. This one *is* the line, so a drive cut off the line
//    comes off the walk too: its coverage, its active time and the end it
//    was cut at.
//  - **What described the old line**: the surface and difficulty breakdowns
//    and the cached climb, emptied so the next open measures the new one.
//
//  Places and photographs are left alone. A place stays on the hike wherever
//  the line now ends, and a photograph taken on a stretch that was cut is in
//  the gallery, where it always was.
//
//  ## A refused save
//
//  Puts everything back, by the two steps the maker's edit takes and for the
//  reasons it gives: the context's rollback, then by hand whatever the
//  rollback left as the edit wrote it, compared first so nothing it did take
//  back is written again.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// A line an edit made, measured off the main actor so the save has nothing
/// to work out.
nonisolated struct EditedLine: Equatable, Sendable {
    let route: [RouteCoordinate]
    /// Its own length, on ``RouteProfile``'s axis.
    let lengthMeters: Double
    /// How much shorter it is than the line it was cut from.
    let removedMeters: Double
    /// How much of the recorded time the cut took — see
    /// ``RouteTrim/recordedSeconds(of:)``.
    let removedSeconds: TimeInterval
    /// ``TrailWalkRecord/routeRevision(of:)`` of the new line.
    let revision: String
    /// The time on the new first point, when the start was cut and it has one.
    let newStart: Date?
    /// The time on the new last point, when the end was cut and it has one.
    let newEnd: Date?

    /// `line` cut down to `range`, or `nil` when that leaves no line.
    ///
    /// - Parameter distances: ``RouteTrim/distances(along:)`` of `line`.
    /// - Parameter pauses: the ends where a cut standing on the end takes off
    ///   the pause there — see ``RouteTrim/EndPauses``.
    init?(
        trimming line: [RouteCoordinate],
        distances: [Double],
        to range: ClosedRange<Double>,
        takingOff pauses: RouteTrim.EndPauses = []
    ) {
        let kept = RouteTrim.trimmed(line, distances: distances, keeping: range, takingOff: pauses)
        guard kept.count > 1, let total = distances.last else { return nil }
        let length = kept.lengthMeters
        guard length > 0 else { return nil }
        route = kept
        lengthMeters = length
        removedMeters = max(0, total - length)
        removedSeconds = max(0, RouteTrim.recordedSeconds(of: line) - RouteTrim.recordedSeconds(of: kept))
        revision = TrailWalkRecord.routeRevision(of: kept)
        newStart = kept.first != line.first ? kept.first?.timestamp : nil
        newEnd = kept.last != line.last ? kept.last?.timestamp : nil
    }
}

/// Why an edit did not land.
enum RouteEditRefusal: LocalizedError, Equatable, Sendable {
    /// The hike's line is no longer the one the edit was made to: it was
    /// edited on the hiker's other device while the editor was open.
    case lineChanged
    /// *Revert* found no original on this device: iCloud has brought the
    /// hike and not yet its original line.
    case noOriginal
    /// The store refused to keep it. No diagnostic, for the reason
    /// ``TrailDraftRefusal/notSaved`` carries none.
    case notSaved

    var errorDescription: String? {
        switch self {
        case .lineChanged, .notSaved: String(localized: "This route couldn’t be saved.")
        case .noOriginal: String(localized: "The original route couldn’t be restored.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .lineChanged:
            String(localized: "The route changed while you were editing it. Check it, then try again.")
        case .noOriginal:
            String(localized: "It isn’t on this device yet. Try again once iCloud has caught up.")
        case .notSaved:
            String(localized: "Your hike wasn’t changed. Check that the device has storage available, then try again.")
        }
    }
}

enum RouteEditOutcome: Equatable, Sendable {
    case refused(RouteEditRefusal)
    /// Saved, with the line the hike has now, for whoever has to tell
    /// Health — see ``RouteEditWorkout``.
    case saved([RouteCoordinate])

    var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

enum RouteEditSave {
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "RouteEdit")

    /// Writes `edited` in place of `line`, the line `hike` had when it was
    /// cut — see the file header for everything that goes with it.
    ///
    /// - Parameter line: the hike's line as the editor read it. Handed in
    ///   rather than read here, where reading it would decode all of it on
    ///   the main actor; the caller has checked it is still the hike's.
    /// - Parameter save: the seam the commit goes through, so a suite can
    ///   refuse it, as in ``TrailDraftSave``.
    @discardableResult static func trim(
        _ hike: Hike,
        from line: [RouteCoordinate],
        to edited: EditedLine,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> RouteEditOutcome {
        guard edited.route.count > 1 else { return .refused(.notSaved) }
        guard commitPending(in: context, save: save) else { return .refused(.notSaved) }
        var edit = hike.routeEdit ?? RouteEdit()
        // Only the first edit writes the original, so only it has one to put
        // back: none.
        let before = Unedited(hike, route: line, original: edit.original == nil ? .was([]) : .untouched)
        if edit.original == nil {
            hike.originalRoute = line
            edit.original = RouteEdit.Original(
                distanceMeters: hike.distanceMeters,
                date: hike.date,
                recordedWalk: before.walk?.figures
            )
        }
        edit.editedUnderSubmissionID = hike.communitySubmissionID
        hike.routeEdit = edit
        replaceLine(of: hike, with: edited.route, before: before)
        hike.distanceMeters = max(0, min(edited.lengthMeters, hike.distanceMeters - edited.removedMeters))
        if let newStart = edited.newStart { hike.date = newStart }
        if let walk = before.walk?.row {
            if let newStart = edited.newStart { walk.startedAt = newStart }
            if let newEnd = edited.newEnd { walk.endedAt = newEnd }
            walk.activeSeconds = max(0, walk.activeSeconds - edited.removedSeconds)
            walk.coveredIntervals = [0, edited.lengthMeters]
            walk.furthestDistanceMeters = edited.lengthMeters
            walk.routeDistanceMeters = edited.lengthMeters
            walk.routeRevision = edited.revision
        }
        return commit(hike, to: edited.route, before: before, in: context, save: save)
    }

    /// Puts back the line `hike` had before its first edit, with the figures
    /// that were its — see ``RouteEdit``.
    ///
    /// - Parameter line: the hike's line now, for the reason
    ///   ``trim(_:from:to:in:save:)`` takes it.
    @discardableResult static func revert(
        _ hike: Hike,
        from line: [RouteCoordinate],
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> RouteEditOutcome {
        guard var edit = hike.routeEdit, let original = edit.original else { return .refused(.noOriginal) }
        // Read here, and on the main actor: it is the one read of it there
        // is, on the tap that asks for it.
        let originalRoute = hike.originalRoute
        guard originalRoute.count > 1 else { return .refused(.noOriginal) }
        guard commitPending(in: context, save: save) else { return .refused(.notSaved) }
        let before = Unedited(hike, route: line, original: .was(originalRoute))
        replaceLine(of: hike, with: originalRoute, before: before)
        hike.originalRoute = []
        hike.distanceMeters = original.distanceMeters
        hike.date = original.date
        if let walk = before.walk?.row { original.recordedWalk?.write(to: walk) }
        edit.original = nil
        // A revert moves the line as an edit does, so a shared copy made of
        // the edited line is now the one out of date.
        edit.editedUnderSubmissionID = hike.communitySubmissionID
        hike.routeEdit = edit
        return commit(hike, to: originalRoute, before: before, in: context, save: save)
    }

    // MARK: The commit

    /// What the context already holds goes first, in a commit of its own:
    /// this is the shared main context, and a rename waiting there for its
    /// autosave is not this edit's to roll back.
    private static func commitPending(in context: ModelContext, save: (ModelContext) throws -> Void) -> Bool {
        do {
            if context.hasChanges { try save(context) }
            return true
        } catch {
            log(error)
            return false
        }
    }

    /// The line, and everything that described the one before it.
    private static func replaceLine(of hike: Hike, with route: [RouteCoordinate], before: Unedited) {
        // Before the line changes: a download recorded without its box has
        // only the route to be recomputed from.
        hike.pinUnboxedDownloads()
        hike.replaceRoute(with: route)
        hike.surfaceMetersByCategory = [:]
        hike.difficultyMetersByGrade = [:]
        if before.climb != nil || before.descent != nil {
            hike.climbMeters = nil
            hike.descentMeters = nil
        }
        if before.elevationRevision != nil { hike.elevationRouteRevision = nil }
    }

    private static func commit(
        _ hike: Hike,
        to route: [RouteCoordinate],
        before: Unedited,
        in context: ModelContext,
        save: (ModelContext) throws -> Void
    ) -> RouteEditOutcome {
        do {
            try save(context)
            return .saved(route)
        } catch {
            context.rollback()
            before.putBack(into: hike)
            log(error)
            return .refused(.notSaved)
        }
    }

    private static func log(_ error: any Error) {
        logger.error("An edited route could not be saved: \(error.localizedDescription, privacy: .public)")
    }

    /// The hike as an edit found it: every column an edit writes, and the
    /// recording's own walk.
    private struct Unedited {
        struct Walk {
            let row: HikeWalk
            let figures: RouteEdit.RecordedWalk
        }

        /// ``Hike/originalRoute`` before the edit, where the edit writes it.
        enum Original {
            /// The edit leaves it alone, so it is neither read nor put back.
            case untouched
            case was([RouteCoordinate])
        }

        let route: [RouteCoordinate]
        let original: Original
        let distance: Double
        let date: Date
        let edit: Data?
        let surface: [String: Double]
        let difficulty: [String: Double]
        let climb: Double?
        let descent: Double?
        let elevationRevision: String?
        let walk: Walk?

        init(_ hike: Hike, route: [RouteCoordinate], original: Original) {
            self.route = route
            self.original = original
            distance = hike.distanceMeters
            date = hike.date
            edit = hike.routeEditData
            surface = hike.surfaceMetersByCategory
            difficulty = hike.difficultyMetersByGrade
            climb = hike.climbMeters
            descent = hike.descentMeters
            elevationRevision = hike.elevationRouteRevision
            walk = hike.recordedWalk.map { Walk(row: $0, figures: RouteEdit.RecordedWalk($0)) }
        }

        /// Writes back what a refused edit's rollback left as the edit wrote
        /// it, and nothing the rollback took back — see
        /// ``TrailDraftSave``'s own, which says why each is compared first.
        func putBack(into hike: Hike) {
            if hike.route != route { hike.replaceRoute(with: route) }
            if case .was(let originalRoute) = original, hike.originalRoute != originalRoute {
                hike.originalRoute = originalRoute
            }
            if hike.distanceMeters != distance { hike.distanceMeters = distance }
            if hike.date != date { hike.date = date }
            if hike.routeEditData != edit { hike.routeEditData = edit }
            if hike.surfaceMetersByCategory != surface { hike.surfaceMetersByCategory = surface }
            if hike.difficultyMetersByGrade != difficulty { hike.difficultyMetersByGrade = difficulty }
            if hike.climbMeters != climb { hike.climbMeters = climb }
            if hike.descentMeters != descent { hike.descentMeters = descent }
            if hike.elevationRouteRevision != elevationRevision { hike.elevationRouteRevision = elevationRevision }
            if let walk, RouteEdit.RecordedWalk(walk.row) != walk.figures { walk.figures.write(to: walk.row) }
        }
    }
}
