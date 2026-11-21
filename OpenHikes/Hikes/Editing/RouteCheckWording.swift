//
//  RouteCheckWording.swift
//  OpenHikes
//
//  What a section to check and its answers are called, on *Edit Route* and on
//  the hike's own screen — see ``RouteChecksCard`` and
//  ``HikeRouteCheckNotice``.
//
//  The words are the ones the review said them in before a recording was
//  saved, so they were translated already. Apart from the views that draw
//  them, so a suite can hold them without a screen.
//

import Foundation
import OpenHikesData

/// What a stretch and its answers are called. The same words the review said
/// them in before a recording was saved, so they are translated already.
nonisolated enum RouteCheckWording {
    static func identifier(for choice: RouteCheck.Choice) -> String {
        switch choice {
        case .matched: "review-choice-trail"
        case .gps: "review-choice-gps"
        case .alternative(let id): "review-choice-alternative-\(id)"
        }
    }

    /// What happened on the stretch.
    static func prompt(for check: RouteCheck) -> String {
        switch check.kind {
        case .snapped:
            return String(localized: "The highlighted section was moved onto a mapped trail.")
        case .ambiguous:
            return gapLead(for: check)
                + String(localized: "The highlighted section has more than one plausible route.")
        case .gap:
            return gapLead(for: check) + (
                check.isBridged
                    ? String(localized: "The highlighted line follows a mapped trail across the gap.")
                    : String(localized: "No mapped route fits the gap, so the line is drawn straight across it.")
            )
        }
    }

    private static func gapLead(for check: RouteCheck) -> String {
        guard let seconds = check.unobservedSeconds else { return "" }
        return String(localized: "No position was recorded for \(HikeFormat.duration(seconds)). ")
    }

    static func title(for choice: RouteCheck.Choice, in check: RouteCheck) -> String {
        switch choice {
        case .matched:
            if let name = check.trailName { return String(localized: "Use \(name)") }
            return String(localized: "Use the mapped trail")
        case .gps:
            if check.kind == .gap { return String(localized: "Draw a straight line") }
            return String(localized: "Use GPS only")
        case .alternative(let id):
            return String(localized: "Option \(optionLabel(id))")
        }
    }

    /// What tells the answer apart from the others: what it follows, and
    /// how long the stretch is under it.
    static func subtitle(for choice: RouteCheck.Choice, in check: RouteCheck, meters: Double) -> String {
        let distance = RouteTrimFormat.length(meters)
        switch choice {
        case .matched:
            return String(localized: "Snapped to the trail · \(distance)")
        case .gps:
            return check.kind == .gap
                ? String(localized: "Straight across the gap · \(distance)")
                : String(localized: "Keep the recorded line · \(distance)")
        case .alternative(let id):
            let names = check.alternatives.first { $0.id == id }?.trailNames ?? []
            let trail = names.isEmpty ? String(localized: "Unnamed trail") : names.joined(separator: ", ")
            return "\(trail) · \(distance)"
        }
    }

    private static let alphabetCount = 26
    private static let uppercaseAScalar = 65

    /// Options are lettered, as the review lettered them.
    static func optionLabel(_ index: Int) -> String {
        guard index >= 0, index < alphabetCount,
              let scalar = UnicodeScalar(uppercaseAScalar + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    /// What the hike's own screen says there is to look at, a line each —
    /// see ``HikeRouteCheckNotice``.
    static func noticeLines(for edit: RouteEdit) -> [String] {
        var lines: [String] = []
        let count = edit.uncheckedCount
        if count > 0 {
            lines.append(String(localized: "\(count) sections to check"))
        }
        if let ends = edit.uncheckedNotOnFoot {
            lines.append(String(localized: "\(RouteTrimFormat.length(ends.totalMeters)) not on foot"))
        }
        return lines
    }
}
