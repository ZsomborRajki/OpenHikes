//
//  WalkShareFigures.swift
//  OpenHikes
//
//  The numbers a walk's share card can print, worked out once when the card
//  is opened rather than on every pass of the editor.
//
//  Every figure is the walk's own, never the trail's: the distance is what the
//  walk covered, the climb is what the covered stretches climb, and the speed
//  is that distance over the active clock — so a walk abandoned halfway does
//  not advertise the whole trail's ascent, and breaks do not drag the pace
//  down. The summary screen beside it shows the trail's figures for context;
//  a card sent to somebody else has no such context to lean on.
//

import Foundation
import OpenHikesData
import OpenHikesShared

/// One figure the stats box can carry.
///
/// The raw values are kept in the saved layout (`SettingsKey.walkShareLayout`),
/// so they are a storage contract: a renamed case drops a hiker's choice.
nonisolated enum WalkShareStat: String, Codable, Sendable {
    case ascent = "ascent"
    case completion = "completion"
    case date = "date"
    case descent = "descent"
    case distance = "distance"
    case speed = "speed"
    case time = "time"

    /// The order the menu offers them in and the box prints them in, which
    /// is how much a hiker is likely to want each rather than the alphabet.
    static let menuOrder: [Self] = [.distance, .ascent, .time, .speed, .descent, .completion, .date]

    /// How many the box holds. Past four it stops being a glance and the
    /// photograph starts losing to the numbers.
    static let maximumShown = 4
    static let defaultShown: [Self] = [.distance, .ascent, .time, .speed]

    var label: String {
        switch self {
        case .distance: String(localized: "Distance")
        case .ascent: String(localized: "Ascent")
        case .time: String(localized: "Time")
        case .speed: String(localized: "Avg Speed")
        case .descent: String(localized: "Descent")
        case .completion: String(localized: "Completed")
        case .date: String(localized: "Date")
        }
    }

    var symbol: String {
        switch self {
        case .distance: "point.topleft.down.to.point.bottomright.curvepath"
        case .ascent: "arrow.up.right"
        case .time: "clock"
        case .speed: "speedometer"
        case .descent: "arrow.down.right"
        case .completion: "flag.checkered"
        case .date: "calendar"
        }
    }
}

/// The walk's figures, as values the share card's renderer can carry off the
/// main actor.
nonisolated struct WalkShareFigures: Equatable, Sendable {
    /// The trail's name, which the card prints over the figures.
    let title: String
    /// What the walk covered — the union of its stretches, not the trail.
    let walkedMeters: Double
    let activeSeconds: Double
    /// The covered stretches' climb, or `nil` when it cannot be said: no
    /// heights on the route, or a route changed since the walk.
    let ascentMeters: Double?
    let descentMeters: Double?
    /// Covered over the trail's length at the time, 0…1.
    let completion: Double
    let startedAt: Date

    /// The covered distance over the active clock, or `nil` for a walk too
    /// short to have a pace.
    var averageMetersPerSecond: Double? {
        guard activeSeconds > 0, walkedMeters > 0 else { return nil }
        return walkedMeters / activeSeconds
    }

    /// The text for `stat`, or `nil` when there is nothing true to print —
    /// which is what takes the row off the card rather than printing a dash
    /// on a picture somebody else will look at.
    func value(of stat: WalkShareStat, locale: Locale = .autoupdatingCurrent) -> String? {
        switch stat {
        case .distance:
            return WidgetFormat.length(meters: walkedMeters, locale: locale)
        case .ascent:
            return ascentMeters.map { WidgetFormat.elevation(meters: $0, locale: locale) }
        case .descent:
            return descentMeters.map { WidgetFormat.elevation(meters: $0, locale: locale) }
        case .time:
            return activeSeconds > 0 ? HikeFormat.duration(activeSeconds) : nil
        case .speed:
            return averageMetersPerSecond.map { WidgetFormat.speed(metersPerSecond: $0, locale: locale) }
        case .completion:
            return completion.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        case .date:
            return startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        }
    }

    /// What the covered stretches climb and drop, summed stretch by stretch
    /// through ``RouteProfile/climb(from:to:)`` — the same deadband every
    /// other climb in the app is counted with. `nil` when no stretch had two
    /// heights to compare.
    static func climb(
        over ranges: [ClosedRange<Double>],
        along profile: RouteProfile
    ) -> (gainMeters: Double, lossMeters: Double)? {
        let climbs = ranges.compactMap { profile.climb(from: $0.lowerBound, to: $0.upperBound) }
        guard !climbs.isEmpty else { return nil }
        return climbs.reduce((gainMeters: 0, lossMeters: 0)) { total, climb in
            (total.gainMeters + climb.gainMeters, total.lossMeters + climb.lossMeters)
        }
    }
}

extension WalkShareFigures {
    /// The figures of `walk`, with its climb read along `profile` when the
    /// route is still the one it was walked along.
    ///
    /// - Parameter profile: `nil` when the trail has changed since the walk —
    ///   the stretches are metres along *that* route, so measuring their
    ///   climb on another would be measuring somewhere else.
    init(walk: HikeWalk, title: String, profile: RouteProfile?) {
        let coverage = walk.coverage
        let climb = profile.flatMap { Self.climb(over: coverage.ranges, along: $0) }
        self.init(
            title: title,
            walkedMeters: coverage.coveredMeters,
            activeSeconds: walk.activeSeconds,
            ascentMeters: climb?.gainMeters,
            descentMeters: climb?.lossMeters,
            completion: walk.coveredFraction,
            startedAt: walk.startedAt
        )
    }
}
