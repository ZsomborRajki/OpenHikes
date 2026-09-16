//
//  WeatherAlertWatch.swift
//  OpenHikes
//
//  Which severe-weather alerts are worth interrupting a walk for, and which
//  have already been said.
//
//  The same shape as ``OffTrailWatch``, and for the same reasons. A value type
//  with no clock and no framework in it, so a suite can drive a day of weather
//  polls through it without waiting for one; and the repeating rule is the
//  strict one — **once per alert**, not once per poll.
//
//  That second half is the whole job. The weather loop re-asks WeatherKit
//  every few minutes, and an agency's storm warning stands for hours, so the
//  same alert comes back on every single request. Without this the hiker gets
//  a banner every poll for the rest of the afternoon, which is the fastest way
//  to teach somebody to ignore the one notification in this app that could
//  matter.
//
//  ## Why a threshold, and why it is where it is
//
//  Not every alert is an interruption. Agencies issue ungraded advisories and
//  minor notices — pollen, a coastal small-craft advisory — and a banner for
//  one of those spends the hiker's attention on something they would not have
//  gone looking for. ``WeatherAlertPolicy/interruptionThreshold`` is where the
//  line sits, and everything below it is still *drawn* in the detail sheet.
//  Nothing is hidden; what is rationed is the interruption.
//

import Foundation

/// The numbers behind the rule, in one place for the reason
/// ``MovementReminderPolicy`` is one.
nonisolated enum WeatherAlertPolicy {
    /// The least severe grade worth a banner.
    ///
    /// `.severe` rather than `.moderate`: a moderate alert is the grade
    /// agencies use for the weather a hiker dressed for, and this app
    /// interrupts for the weather they did not. Everything below the line is
    /// still in the sheet.
    static let interruptionThreshold: WeatherAlertSeverity = .severe

    /// How many distinct alerts are remembered as already-said.
    ///
    /// Bounded because the watch outlives a walk and a hiker moving through
    /// weather over a week would otherwise grow the set forever. Well above
    /// any plausible number standing over one place at one time, so the bound
    /// is a leak stop rather than a policy — evicting an alert that is still
    /// standing would re-announce it, which is exactly what this type exists
    /// to prevent.
    static let rememberedAlertLimit = 64
}

/// One subject's relationship to the alerts standing over it.
nonisolated struct WeatherAlertWatch: Equatable {
    /// The identifiers already announced, oldest first.
    ///
    /// An array rather than a `Set` because eviction needs an order, and at
    /// ``WeatherAlertPolicy/rememberedAlertLimit`` entries a linear
    /// `contains` is cheaper than the hashing it would replace.
    private var announced: [String] = []

    init() {
        // Nothing announced yet, which is what a fresh watch means.
    }

    /// Records what the latest reading said, and answers with the alerts the
    /// hiker should be interrupted for.
    ///
    /// Returns the ones that are **both** at or above the threshold and not
    /// already announced, worst first — so a caller posting only the first
    /// gets the worst one. Empty is the ordinary answer and means nothing new
    /// is worth saying.
    ///
    /// ``WeatherAlerts/unavailable`` and ``WeatherAlerts/clear`` both return
    /// empty and neither clears what has been announced. *Unavailable* is the
    /// app learning nothing rather than learning the storm is over; and a
    /// *clear* reading is a genuine all-clear, but re-announcing a warning
    /// that lapsed and was re-issued under the same identifier is a smaller
    /// harm than silence, so forgetting is left to the bound above.
    mutating func observed(_ alerts: WeatherAlerts) -> [WeatherAlertSummary] {
        let worthSaying = alerts.summaries
            .filter { $0.severity >= WeatherAlertPolicy.interruptionThreshold }
            .filter { !announced.contains($0.id) }
            .sorted { $0.severity > $1.severity }

        for alert in worthSaying {
            announced.append(alert.id)
        }
        if announced.count > WeatherAlertPolicy.rememberedAlertLimit {
            announced.removeFirst(announced.count - WeatherAlertPolicy.rememberedAlertLimit)
        }
        return worthSaying
    }

    /// Forgets everything, so the next reading announces whatever stands.
    ///
    /// What a hiker switching to a different trail does: an alert already
    /// announced over one ridge is news again over another, because it is a
    /// different place they are being warned about.
    mutating func reset() {
        announced.removeAll()
    }

    /// Whether anything has been announced yet, for a caller deciding whether
    /// a standing banner is still this watch's.
    var hasAnnounced: Bool { !announced.isEmpty }
}
