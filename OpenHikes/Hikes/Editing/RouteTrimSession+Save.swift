//
//  RouteTrimSession+Save.swift
//  OpenHikes
//
//  What *Save* and *Revert to Original* do with a visit's cuts: the checks
//  that belong to the screen rather than to the write, and the workout that
//  follows it into Health.
//
//  Here and not in the screen, which is body code no hosted suite evaluates:
//  whether the line the cuts were made on is still the hike's, and whether
//  Health is owed a replacement, are decisions worth a test each.
//

import Foundation
import OpenHikesData
import SwiftData

extension RouteTrimSession {
    /// The hike a visit writes into, and what the write needs of the screen.
    struct Destination {
        let hike: Hike
        let context: ModelContext
        /// `nil` on a launch with no Health, which is every hosted suite's
        /// unless it hands one in.
        var health: RouteEditWorkout.Health?
        /// The hike's line as its screens hold it, or no line while a newer
        /// one is still being read — see ``ShownLine/isSettled``.
        let settledLine: () -> [RouteCoordinate]
        /// Waits until ``settledLine`` answers for every save of the hike's
        /// row this device has heard of: until then the hike can hold a line
        /// another context saved while the line its screens hold still reads
        /// as settled — see ``ShownLine/settle()``. Nothing to wait for by
        /// default, as for a suite that hands in a line of its own.
        var settle: () async -> Void = { /* nothing being brought in */ }
        /// The seam the commit goes through, as in ``RouteEditSave``.
        var save: (ModelContext) throws -> Void = { try $0.save() }
    }

    /// Writes the cuts and the answers into the hike. A line edited on the
    /// hiker's other device while this screen was open is not the line they
    /// were made on, and is refused rather than cut by distances that were
    /// another line's.
    ///
    /// - Returns: whether it landed. A refusal is in ``refusal``.
    @discardableResult func save(to destination: Destination) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        // After the line has caught up with the last answer given — see
        // ``editedLine()``.
        guard let edited = await editedLine(), let sources else { return false }
        // And once any line another device saved is in — see
        // ``Destination/settle``.
        await destination.settle()
        guard destination.settledLine() == sources.current else {
            refusal = .lineChanged
            return false
        }
        // Every cut moved back out and every answer put back is the line as
        // it was saved, and is saved as that: with the figures it had, where
        // an edit would only come close to them.
        if edited.route == sources.saved, edited.steps.isEmpty, edited.assembly?.isAsSaved != false,
           sources.edit?.original != nil {
            return land(revertOutcome(in: destination, from: sources.current), in: destination)
        }
        let outcome = RouteEditSave.write(
            edited,
            to: destination.hike,
            replacing: sources.current,
            in: destination.context,
            save: destination.save
        )
        return land(outcome, in: destination)
    }

    /// Puts the hike's original line back.
    @discardableResult func revert(in destination: Destination) -> Bool {
        guard !isSaving else { return false }
        let base = destination.settledLine()
        guard base.count > 1 else {
            refusal = .lineChanged
            return false
        }
        return land(revertOutcome(in: destination, from: base), in: destination)
    }

    /// Says the line is right as it is: every stretch to check counts as
    /// looked at, and nothing about the line changes — see
    /// ``RouteEditSave/markChecked(_:in:save:)``. Once the line has caught
    /// up with the last answer given, and only if that left nothing changed:
    /// an answer given on the way to it is the hiker's, and Save keeps it.
    ///
    /// The look is at the line and the record the screen showed when the
    /// hiker tapped, and is refused, as Save refuses, when the hike no longer
    /// holds both: an edit from the other device can land while this screen
    /// is up and before it has reloaded, and its checks are ones nobody here
    /// has seen. They stay owed, and the screen loads them.
    ///
    /// - Parameter shown: the ``sourcesRevision`` the button was drawn over.
    ///   Taken there rather than here, because a reload already queued when
    ///   the hiker tapped lands before this runs, and its checks would be
    ///   the ones looked at. The record is held to by its bytes — see
    ///   ``RouteEditSources/recordData``.
    @discardableResult func confirmChecks(in destination: Destination, tappedOn shown: Int) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        await settled()
        await destination.settle()
        guard let sources, !hasChanges else { return false }
        guard sourcesRevision == shown,
              destination.settledLine() == sources.current,
              let record = sources.recordData, destination.hike.routeEditData == record
        else {
            refusal = .lineChanged
            return false
        }
        guard let edit = RouteEditSave.markChecked(destination.hike, in: destination.context, save: destination.save)
        else { return false }
        // The hike's line has not moved, so nothing reloads this visit: it
        // takes the looks itself, on what it works from and on what it shows.
        let looked = RouteEditSources(
            current: sources.current,
            saved: sources.saved,
            raw: sources.raw,
            edit: edit,
            recordData: destination.hike.routeEditData
        )
        adopt(looked)
        return true
    }

    private func revertOutcome(in destination: Destination, from base: [RouteCoordinate]) -> RouteEditOutcome {
        RouteEditSave.revert(destination.hike, from: base, in: destination.context, save: destination.save)
    }

    private func land(_ outcome: RouteEditOutcome, in destination: Destination) -> Bool {
        switch outcome {
        case .refused(let refusal):
            self.refusal = refusal
            return false
        case .saved(let route):
            replaceWorkout(of: destination.hike, with: route, through: destination.health)
            return true
        }
    }

    /// After the save, and only after one that landed, for the reason the
    /// recorder's export is: Health must never describe a hike this app does
    /// not hold. Fired off rather than awaited, as that export is.
    private func replaceWorkout(
        of hike: Hike,
        with route: [RouteCoordinate],
        through health: RouteEditWorkout.Health?
    ) {
        guard let health, RouteEditWorkout.isOwed(for: hike, in: health.defaults) else { return }
        let hikeID = hike.id
        let distance = hike.distanceMeters
        workoutReplacement = RouteEditWorkout.replace(
            of: hikeID,
            with: route,
            distanceMeters: distance,
            through: health
        )
    }
}

extension RouteTrimSession.Destination {
    /// Where *Edit Route* writes: `hike`, whose line its screens hold as
    /// `line`. A line still being read, or one another context saved that is
    /// still being brought in, is no line to write against.
    init(hike: Hike, context: ModelContext, health: RouteEditWorkout.Health?, line: ShownLine) {
        self.init(
            hike: hike,
            context: context,
            health: health,
            settledLine: { [line] in line.isSettled ? line.current?.route ?? [] : [] },
            settle: { [line] in await line.settle() }
        )
    }
}
