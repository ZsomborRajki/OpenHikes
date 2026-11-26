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
//  A banner the notification centre then refuses reached nobody, so its
//  commitment is taken back while the condition it was about lasts, and the
//  next observation that qualifies proposes and posts it again (#1682). One
//  that lands after the condition ended or was replaced touches nothing: a
//  rejoin, the walk's end or moving again has re-armed the watch already, and
//  a newer departure is not this banner's to un-say.
//
//  Leaving the trail is also asked about in the app, and that needs nobody's
//  permission. So a second watch counts the same departures for it, shown
//  every fix the first is and committed as it observes: the question is asked
//  on the fix the banner is first tried on, once per departure, whatever
//  becomes of the banner.
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
    /// The departures ``offTrail`` counts, as the app's own question counts
    /// them — see this file's header.
    private var offTrailQuestion = OffTrailWatch()
    private var dusk = DuskWatch()
    private var stillness = StillnessWatch()
    private var pendingWarnings: [MovementReminderKind: PendingWarning] = [:]
    /// The proposal each watch was last committed for, for as long as the
    /// condition it was said about lasts — see ``retract(_:id:)``.
    private var spent: [MovementReminderKind: UUID] = [:]

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
            // Moving again ends the stop, and re-arms the watch itself.
            if !isStationary { spent[.pauseRecording] = nil }
            return false
        }
        prepare(
            MovementReminderWording.pauseRecording(stillFor: MovementReminderPolicy.stillFor),
            watch: .stillness(reported)
        )
        return true
    }

    /// Whether this fix is the one a departure becomes worth asking the hiker
    /// about on: once per departure, on the fix
    /// ``observeOffTrail(offRouteMeters:trailTitle:at:)`` first proposes its
    /// banner on. Shown every fix that one is.
    mutating func observeDeparture(offRouteMeters: Double?, at date: Date) -> Bool {
        offTrailQuestion.observed(offRouteMeters: offRouteMeters, at: date)
    }

    mutating func observeOffTrail(offRouteMeters: Double?, trailTitle: String, at date: Date) -> Bool {
        // An unmatched fix says nothing new, including about a warning that
        // is already waiting for permission. The watch follows the same rule.
        guard let offRouteMeters, offRouteMeters.isFinite else { return false }
        var reported = offTrail
        guard reported.observed(offRouteMeters: offRouteMeters, at: date) else {
            offTrail = reported
            // Rejoining ends the departure, and re-arms the watch itself.
            if !reported.isOffTrail { spent[.leftTheTrail] = nil }
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
        spent[kind] = id
        return warning.reminder
    }

    /// Takes back what ``take(_:id:at:)`` committed for proposal `id`, for a
    /// banner the notification centre refused: the watch reads as unsaid
    /// again, and the next observation that qualifies proposes it anew.
    ///
    /// Only while the condition it was said about lasts — see this file's
    /// header.
    mutating func retract(_ kind: MovementReminderKind, id: UUID) {
        guard spent[kind] == id else { return }
        spent[kind] = nil
        switch kind {
        case .leftTheTrail: offTrail.retractReport()
        case .afterDark: dusk.retractReport()
        case .pauseRecording: stillness.retractReport()
        default: break
        }
    }

    mutating func resetRecording() {
        stillness = StillnessWatch()
        pendingWarnings[.pauseRecording] = nil
        spent[.pauseRecording] = nil
    }

    mutating func cancelWalkWarnings() {
        pendingWarnings[.leftTheTrail] = nil
        pendingWarnings[.afterDark] = nil
    }

    mutating func stopFollowing() {
        offTrail.reset()
        offTrailQuestion.reset()
        dusk.reset()
        spent[.leftTheTrail] = nil
        spent[.afterDark] = nil
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
