//
//  MovementWarningState.swift
//  OpenHikes
//
//  The once-only warnings have two decisions: whether the latest observation
//  warrants a banner, and whether permission lets it be posted. Keep the watch
//  that would spend the allowance as a proposal until the second decision.
//  A refusal leaves the original watch unsaid without losing its dwell time.
//
//  The proposal's identity belongs to its uninterrupted condition. A rejoin,
//  an earlier finish, movement or an ended subject removes it; another eligible
//  observation updates its wording while keeping the identity. An answer to a
//  slow permission prompt can therefore use the latest facts, but cannot post
//  for a departure or walk that replaced the one that asked.
//
//  Taking a proposal commits its watch before the notifier suspends again.
//  Overlapping attempts find no proposal left, so they cannot post twice.
//

import Foundation

struct MovementWarningState {
    private enum ReportedWatch {
        case offTrail(OffTrailWatch)
        case dusk(DuskWatch)
        case stillness(StillnessWatch)
    }

    private struct PendingWarning {
        let id: UUID
        let watch: ReportedWatch
        let reminder: MovementReminder
        let expiresAt: Date?
    }

    private var offTrail = OffTrailWatch()
    private var dusk = DuskWatch()
    private var stillness = StillnessWatch()
    private var pendingWarnings: [MovementReminderKind: PendingWarning] = [:]

    var isOffTrail: Bool { offTrail.isOffTrail }

    var pending: [(kind: MovementReminderKind, id: UUID)] {
        MovementReminderKind.allCases.compactMap { kind in
            pendingWarnings[kind].map { (kind, $0.id) }
        }
    }

    func pendingID(for kind: MovementReminderKind) -> UUID? {
        pendingWarnings[kind]?.id
    }

    mutating func observeStillness(isStationary: Bool, at date: Date) -> Bool {
        var reported = stillness
        guard reported.observe(isStationary: isStationary, at: date) else {
            stillness = reported
            pendingWarnings[.pauseRecording] = nil
            return false
        }
        prepare(
            MovementReminderWording.pauseRecording(stillFor: MovementReminderPolicy.stillFor),
            watch: .stillness(reported)
        )
        return true
    }

    mutating func observeOffTrail(offRouteMeters: Double?, trailTitle: String, at date: Date) -> Bool {
        // An unmatched fix says nothing new, including about a warning that
        // is already waiting for permission. The watch follows the same rule.
        guard let offRouteMeters, offRouteMeters.isFinite else { return false }
        var reported = offTrail
        guard reported.observed(offRouteMeters: offRouteMeters, at: date) else {
            offTrail = reported
            // The hysteresis band preserves an established departure. It
            // cannot mature a new warning, but it cannot cancel an already
            // mature one either; only a true rejoin does that.
            if reported.isOffTrail, let warning = pendingWarnings[.leftTheTrail] {
                prepare(
                    MovementReminderWording.leftTheTrail(trailTitle: trailTitle, offRouteMeters: offRouteMeters),
                    watch: warning.watch
                )
            } else {
                pendingWarnings[.leftTheTrail] = nil
            }
            return false
        }
        prepare(
            MovementReminderWording.leftTheTrail(trailTitle: trailTitle, offRouteMeters: offRouteMeters),
            watch: .offTrail(reported)
        )
        return true
    }

    mutating func estimateFinish(
        finishAt: Date,
        civilDusk: Date?,
        trailTitle: String,
        at date: Date
    ) -> Bool {
        var reported = dusk
        guard reported.observed(finishAt: finishAt, civilDusk: civilDusk, now: date),
              let civilDusk else {
            pendingWarnings[.afterDark] = nil
            return false
        }
        prepare(
            MovementReminderWording.afterDark(trailTitle: trailTitle, finishAt: finishAt, civilDusk: civilDusk),
            watch: .dusk(reported),
            expiresAt: civilDusk
        )
        return true
    }

    /// Removes only this proposal and spends its allowance. The identity
    /// check and the commitment happen together, with no suspension between.
    mutating func take(_ kind: MovementReminderKind, id: UUID, at date: Date) -> MovementReminder? {
        guard let warning = pendingWarnings[kind], warning.id == id else { return nil }
        pendingWarnings[kind] = nil
        if let expiresAt = warning.expiresAt, date >= expiresAt { return nil }
        switch warning.watch {
        case let .offTrail(reported): offTrail = reported
        case let .dusk(reported): dusk = reported
        case let .stillness(reported): stillness = reported
        }
        return warning.reminder
    }

    mutating func resetRecording() {
        stillness = StillnessWatch()
        pendingWarnings[.pauseRecording] = nil
    }

    mutating func cancelWalkWarnings() {
        pendingWarnings[.leftTheTrail] = nil
        pendingWarnings[.afterDark] = nil
    }

    mutating func stopFollowing() {
        offTrail.reset()
        dusk.reset()
        cancelWalkWarnings()
    }

    private mutating func prepare(
        _ reminder: MovementReminder,
        watch: ReportedWatch,
        expiresAt: Date? = nil
    ) {
        pendingWarnings[reminder.kind] = PendingWarning(
            id: pendingWarnings[reminder.kind]?.id ?? UUID(),
            watch: watch,
            reminder: reminder,
            expiresAt: expiresAt
        )
    }
}
