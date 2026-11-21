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
    /// The two cuts an edit makes on the whole line.
    struct Cuts: Equatable, Sendable {
        /// Where the kept line begins and ends, in metres along the whole
        /// line, or `nil` for all of it — see ``RouteEdit/trim``.
        var range: ClosedRange<Double>?
        /// The pauses standing on the whole line's own ends that the cuts
        /// take off — see ``RouteTrim/EndPauses``.
        var takingOff: RouteTrim.EndPauses = []

        /// The ends of a whole line `wholeMeters` long that these take
        /// anything off, by the rule ``RouteTrimSession/cuts(_:)`` keeps.
        func ends(alongWholeOf wholeMeters: Double) -> Set<RouteTrimHandle> {
            var ends: Set<RouteTrimHandle> = []
            guard let range else { return ends }
            if range.lowerBound > 0 || takingOff.contains(.start) { ends.insert(.start) }
            if range.upperBound < wholeMeters || takingOff.contains(.end) { ends.insert(.end) }
            return ends
        }
    }

    /// The steps made on the whole line before it was cut — see
    /// ``RouteStep``.
    struct Steps: Equatable, Sendable {
        var made: [RouteStep] = []
        /// The ends of the line they moved — see
        /// ``RouteSteps/Applied``. An end a step moved is an end cut, for
        /// what a save does to the clock there.
        var moving: Set<RouteTrimHandle> = []
        /// The recorded time they leave, carried through any that cleared
        /// the line's clock — see ``RouteSteps/Applied/recordedSeconds``.
        /// `nil` for the line's own.
        var recordedSeconds: TimeInterval?
        /// The line before the first of them that cleared its clock, or
        /// empty — see ``RouteSteps/Applied/clockedRoute``.
        var clockedRoute: [RouteCoordinate] = []
    }

    /// What a save does to the clock at one end of the walk: the hike's
    /// date at its start, and the recording's own walk at both.
    ///
    /// Moved only by a cut, never by what an answer draws: a stretch at the
    /// end of the line drawn as its fixes instead of the trail has a first
    /// point of its own, and the walk still began when Start was pressed,
    /// which is before any fix.
    enum ClockEnd: Equatable, Sendable {
        /// Left as it is: the end was not cut and is not, or is cut where it
        /// was.
        case unchanged
        /// Cut, so the walk begins or ends at this time, the cut's.
        case cut(Date)
        /// An earlier cut is gone: the end goes back to the one the hike had
        /// before its first edit — see ``RouteEdit/Original``.
        case uncut
    }

    let route: [RouteCoordinate]
    /// The line a workout of the walk is written from — see
    /// ``RouteEditWorkout``: this one, or, where a step took its clock away,
    /// the line before that step, which the walk's time was last read off.
    let workoutRoute: [RouteCoordinate]
    /// Its own length, on ``RouteProfile``'s axis.
    let lengthMeters: Double
    /// How much shorter it is than the line the hike has now. Less than
    /// nothing for an edit that gives ground back: a handle dragged out over
    /// what an earlier save cut off.
    let removedMeters: Double
    /// How much less recorded time it holds than the line the hike has now,
    /// by ``RouteTrim/recordedSeconds(of:)`` carried through the steps — see
    /// ``recordedSeconds(of:cutTo:steps:)``. Less than nothing for the same
    /// edit.
    let removedSeconds: TimeInterval
    /// ``TrailWalkRecord/routeRevision(of:)`` of the new line.
    let revision: String
    /// What the save does to when the walk began — see ``ClockEnd``.
    let start: ClockEnd
    /// What the save does to when it ended.
    let end: ClockEnd
    /// The two cuts that made it — see ``Cuts``.
    let cuts: Cuts
    /// The steps made on the whole line before the cuts.
    let steps: [RouteStep]
    /// The whole line's pieces under the answers the edit leaves, or `nil`
    /// for a hike with no stretches to check.
    let assembly: RouteAssembly?
    /// The ends of the new line that were not walked.
    let notOnFoot: RouteEdit.NotOnFoot?

    /// `whole` cut down to `trim`, or `nil` when that leaves no line.
    ///
    /// - Parameters:
    ///   - whole: The whole line, under the answers of `assembly` — see
    ///     ``RouteEditSources``.
    ///   - distances: ``RouteTrim/distances(along:)`` of `whole`.
    ///   - cuts: Where the kept line begins and ends on it.
    ///   - current: The line the hike has now, which this one replaces.
    ///   - cutBefore: The ends of the whole line the hike's trim took
    ///     something off when the edit began — see ``ClockEnd``.
    ///   - assembly: The whole line's pieces under the answers that made
    ///     `whole`, for a hike that has any.
    ///   - steps: The steps `whole` already has made on it.
    ///   - recordedBefore: The recorded time of the line the hike has now,
    ///     carried as ``recordedSeconds(of:cutTo:steps:)`` carries it, or
    ///     `nil` to read it off `current`.
    init?(
        whole: [RouteCoordinate],
        distances: [Double],
        cuts: Cuts,
        replacing current: [RouteCoordinate],
        cutBefore: Set<RouteTrimHandle> = [],
        assembly: RouteAssembly? = nil,
        steps: Steps = Steps(),
        recordedBefore: TimeInterval? = nil
    ) {
        let kept = cuts.range.map { range in
            RouteTrim.trimmed(whole, distances: distances, keeping: range, takingOff: cuts.takingOff)
        } ?? whole
        guard kept.count > 1 else { return nil }
        let length = kept.lengthMeters
        guard length > 0 else { return nil }
        route = kept
        workoutRoute = steps.clockedRoute.isEmpty ? kept : steps.clockedRoute
        lengthMeters = length
        removedMeters = current.lengthMeters - length
        // A line with no times leaves the walk's time as it was, as it
        // always has.
        let before = recordedBefore ?? RouteTrim.recordedSeconds(of: current)
        let now = Self.recordedSeconds(of: whole, cutTo: kept, steps: steps)
        removedSeconds = before > 0 && now > 0 ? before - now : 0
        revision = TrailWalkRecord.routeRevision(of: kept)
        let cutNow = cuts.ends(alongWholeOf: distances.last ?? 0).union(steps.moving)
        start = Self.clock(
            isCut: cutNow.contains(.start),
            wasCut: cutBefore.contains(.start),
            at: kept.first?.timestamp,
            before: current.first?.timestamp
        )
        end = Self.clock(
            isCut: cutNow.contains(.end),
            wasCut: cutBefore.contains(.end),
            at: kept.last?.timestamp,
            before: current.last?.timestamp
        )
        self.cuts = cuts
        self.steps = steps.made
        self.assembly = assembly
        // A save is a look: the hiker has had the line in front of them.
        notOnFoot = RouteEdit.NotOnFoot(
            RouteCarriedEnds.found(in: kept, distances: RouteTrim.distances(along: kept)),
            isChecked: true
        )
    }

    /// The recorded time of `whole` cut down to `kept`: what `steps` carried,
    /// less what the cuts take off. A line turned round or begun somewhere
    /// else has no clock and is no less a walk for it, so its figure is the
    /// one the steps carried through, whichever of them were saved first —
    /// see *The clock a step leaves* in `RouteStep.swift`.
    static func recordedSeconds(
        of whole: [RouteCoordinate],
        cutTo kept: [RouteCoordinate],
        steps: Steps = Steps()
    ) -> TimeInterval {
        let own = RouteTrim.recordedSeconds(of: whole)
        return (steps.recordedSeconds ?? own) + RouteTrim.recordedSeconds(of: kept) - own
    }

    /// What a save does to the clock at one end — see ``ClockEnd``.
    ///
    /// - Parameters:
    ///   - time: The time on the kept line's point at that end.
    ///   - before: The time on the point the hike's line has there now.
    private static func clock(isCut: Bool, wasCut: Bool, at time: Date?, before: Date?) -> ClockEnd {
        guard isCut else { return wasCut ? .uncut : .unchanged }
        // A line with no times leaves the clock as it was, as it always has.
        guard let time, !wasCut || time != before else { return .unchanged }
        return .cut(time)
    }
}

/// Why an edit did not land.
enum RouteEditRefusal: LocalizedError, Equatable, Sendable {
    /// The hike's line is no longer the one the edit was made to: it was
    /// edited on the hiker's other device while the editor was open.
    case lineChanged
    /// *Follow Trails* found no mapped path between the two ends of the
    /// stretch — see ``RouteReroute``.
    case noMappedWay
    /// *Revert* found no original on this device: iCloud has brought the
    /// hike and not yet its original line.
    case noOriginal
    /// *Edit Route* found the same on its way in, of the original or of the
    /// recorded trace a section's answer is drawn from. The hike's cuts and
    /// its sections are measured on those, so nothing can be edited until
    /// they have come. Or it found an edit record that does not read, which
    /// a later build wrote — see ``Hike/hasUnreadableRouteEdit``.
    case notHereYet
    /// The store refused to keep it. No diagnostic, for the reason
    /// ``TrailDraftRefusal/notSaved`` carries none.
    case notSaved
    /// The paths drawn across the hike's stretches would be more than a
    /// hike's record keeps — see ``RouteSteps/maximumPathCoordinates``.
    case tooMuchToKeep

    var errorDescription: String? {
        switch self {
        case .lineChanged, .notSaved: String(localized: "This route couldn’t be saved.")
        case .noOriginal: String(localized: "The original route couldn’t be restored.")
        case .notHereYet: String(localized: "This route can’t be edited yet.")
        case .noMappedWay: String(localized: "No trail was found between these points.")
        case .tooMuchToKeep: String(localized: "This stretch is too long to redraw.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .lineChanged:
            String(localized: "The route changed while you were editing it. Check it, then try again.")
        case .noOriginal, .notHereYet:
            String(localized: "It isn’t on this device yet. Try again once iCloud has caught up.")
        case .notSaved:
            String(localized: "Your hike wasn’t changed. Check that the device has storage available, then try again.")
        case .noMappedWay:
            String(localized: "Move the handles onto mapped trails, or straighten the stretch instead.")
        case .tooMuchToKeep:
            String(localized: "Pick a shorter stretch, or undo an earlier change first.")
        }
    }
}

enum RouteEditOutcome: Equatable, Sendable {
    case refused(RouteEditRefusal)
    /// Saved, with the line whose clock Health's workout is written from —
    /// see ``EditedLine/workoutRoute``.
    case saved([RouteCoordinate])

    var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

enum RouteEditSave {
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "RouteEdit")

    /// Writes `edited` in place of `line`, the line `hike` has — see the
    /// file header for everything that goes with it.
    ///
    /// - Parameter line: the hike's line as the editor read it. Handed in
    ///   rather than read here, where reading it would decode all of it on
    ///   the main actor; the caller has checked it is still the hike's.
    /// - Parameter save: the seam the commit goes through, so a suite can
    ///   refuse it, as in ``TrailDraftSave``.
    @discardableResult static func write(
        _ edited: EditedLine,
        to hike: Hike,
        replacing line: [RouteCoordinate],
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> RouteEditOutcome {
        guard edited.route.count > 1 else { return .refused(.notSaved) }
        // A record that is there and does not read is not a hike never
        // edited, whose first edit writes the original.
        guard !hike.hasUnreadableRouteEdit else { return .refused(.notHereYet) }
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
                recordedWalk: before.walk?.figures,
                notOnFoot: edit.notOnFoot
            )
        }
        edit.editedUnderSubmissionID = hike.communitySubmissionID
        edit.assembly = edited.assembly ?? edit.assembly
        edit.trim = edited.cuts.range
        edit.endPausesTakenOff = edited.cuts.range == nil ? [] : edited.cuts.takingOff
        edit.routeSteps = edited.steps
        edit.notOnFoot = edited.notOnFoot
        hike.routeEdit = edit
        replaceLine(of: hike, with: edited.route, before: before)
        hike.distanceMeters = max(0, min(edited.lengthMeters, hike.distanceMeters - edited.removedMeters))
        moveClocks(of: hike, walk: before.walk?.row, to: edited, original: edit.original)
        if let walk = before.walk?.row {
            walk.activeSeconds = max(0, walk.activeSeconds - edited.removedSeconds)
            walk.coveredIntervals = [0, edited.lengthMeters]
            walk.furthestDistanceMeters = edited.lengthMeters
            walk.routeDistanceMeters = edited.lengthMeters
            walk.routeRevision = edited.revision
        }
        return commit(hike, to: edited.workoutRoute, before: before, in: context, save: save)
    }

    /// Puts back the line `hike` had before its first edit, with the figures
    /// that were its — see ``RouteEdit``.
    ///
    /// - Parameter line: the hike's line now, for the reason
    ///   ``write(_:to:replacing:in:save:)`` takes it.
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
        // Every stretch back to the way it was saved, the looks kept: a
        // stretch the hiker has answered for once is not asked about again.
        edit.assembly = edit.assembly?.asSaved
        edit.trim = nil
        edit.endPausesTakenOff = []
        edit.routeSteps = []
        edit.notOnFoot = original.notOnFoot
        edit.notOnFoot?.isChecked = true
        // A revert moves the line as an edit does, so a shared copy made of
        // the edited line is now the one out of date.
        edit.editedUnderSubmissionID = hike.communitySubmissionID
        hike.routeEdit = edit
        return commit(hike, to: originalRoute, before: before, in: context, save: save)
    }

    /// Says the hiker has looked at everything the hike asked them to, and
    /// changes nothing else: the answer to "is the line right?" was yes.
    ///
    /// - Returns: the hike's edit record as it now stands, or `nil` when the
    ///   store refused to keep it.
    @discardableResult static func markChecked(
        _ hike: Hike,
        in context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> RouteEdit? {
        guard let edit = hike.routeEdit?.looked, edit.isOwedALook == false, hike.routeEdit?.isOwedALook == true else {
            return hike.routeEdit
        }
        let before = hike.routeEditData
        hike.routeEdit = edit
        do {
            try save(context)
            return edit
        } catch {
            if hike.routeEditData != before { hike.routeEditData = before }
            log(error)
            return nil
        }
    }

    /// When the hike began, and when its recording's own walk began and
    /// ended, as `edited` moves them — see ``EditedLine/ClockEnd``. An end
    /// uncut goes back to what it was before the first edit.
    private static func moveClocks(
        of hike: Hike,
        walk: HikeWalk?,
        to edited: EditedLine,
        original: RouteEdit.Original?
    ) {
        let walked = original?.recordedWalk
        switch edited.start {
        case .unchanged:
            break
        case .cut(let time):
            hike.date = time
            walk?.startedAt = time
        case .uncut:
            if let original { hike.date = original.date }
            if let walked { walk?.startedAt = walked.startedAt }
        }
        switch edited.end {
        case .unchanged: break
        case .cut(let time): walk?.endedAt = time
        case .uncut: if let walked { walk?.endedAt = walked.endedAt }
        }
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
