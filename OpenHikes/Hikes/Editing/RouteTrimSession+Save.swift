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
        /// The seam the commit goes through, as in ``RouteEditSave``.
        var save: (ModelContext) throws -> Void = { try $0.save() }
    }

    /// Writes the cuts into the hike. A line edited on the hiker's other
    /// device while this screen was open is not the line the cuts were made
    /// on, and is refused rather than cut by distances that were another
    /// line's.
    ///
    /// - Returns: whether it landed. A refusal is in ``refusal``.
    @discardableResult func save(to destination: Destination) async -> Bool {
        guard !isSaving, let base = line?.route else { return false }
        isSaving = true
        defer { isSaving = false }
        guard let edited = await editedLine() else { return false }
        guard destination.settledLine() == base else {
            refusal = .lineChanged
            return false
        }
        let outcome = RouteEditSave.trim(
            destination.hike,
            from: base,
            to: edited,
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
        let outcome = RouteEditSave.revert(
            destination.hike,
            from: base,
            in: destination.context,
            save: destination.save
        )
        return land(outcome, in: destination)
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
