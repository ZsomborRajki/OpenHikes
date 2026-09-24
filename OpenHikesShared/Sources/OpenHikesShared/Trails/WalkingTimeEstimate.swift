//
//  WalkingTimeEstimate.swift
//  OpenHikesShared
//
//  How long a route takes on foot when nobody has walked it with a clock.
//
//  ## Why DIN 33466
//
//  It is the rule the German, Austrian and Swiss Alpine clubs sign their
//  paths with, and the SAC grades this app already reads for *Surface and
//  difficulty* come from the same tradition, so a hiker comparing this figure
//  with a yellow signpost is comparing like with like. Naismith's rule (an
//  hour per five kilometres plus one per six hundred metres of ascent) is the
//  English-speaking alternative and is simpler, but it ignores descent — and
//  descent is the half of a mountain walk that takes longer than the flat
//  ground it covers.
//
//  The rule: 4 km/h on the flat, 300 m/h going up and 500 m/h going down. The
//  horizontal and the vertical times are not added, because a hiker climbing
//  is also moving forward: the larger of the two counts in full and the
//  smaller at half.
//
//  ## What it is not
//
//  A measurement. Nothing that shows this figure may present it as one, and
//  a route with a real clock never shows it at all — the two are not drawn
//  together. It is the time a fit adult takes with no breaks, which is also
//  what the signposts say.
//
//  In this package rather than in the app because the widget, the Live
//  Activity and the watch are the surfaces a walk is followed on, and "how
//  long is left" has to mean the same thing on all of them.
//

import Foundation

public enum WalkingTimeEstimate {
    /// Horizontal pace on the flat, in metres per hour.
    public static let flatMetersPerHour = 4000.0
    /// Ascent per hour.
    public static let ascentMetersPerHour = 300.0
    /// Descent per hour.
    public static let descentMetersPerHour = 500.0

    /// DIN 33466's walking time for a route of this length and relief, in
    /// seconds.
    ///
    /// Negative and non-finite inputs count as zero rather than producing a
    /// negative or NaN time: a route's figures are already clamped where they
    /// are measured, and this is the last place one that was not could reach
    /// a screen.
    public static func seconds(
        distanceMeters: Double,
        ascentMeters: Double,
        descentMeters: Double
    ) -> TimeInterval {
        let horizontal = sanitized(distanceMeters) / flatMetersPerHour
        let vertical = sanitized(ascentMeters) / ascentMetersPerHour
            + sanitized(descentMeters) / descentMetersPerHour
        let hours = max(horizontal, vertical) + min(horizontal, vertical) / 2
        return hours * 3600
    }

    private static func sanitized(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
