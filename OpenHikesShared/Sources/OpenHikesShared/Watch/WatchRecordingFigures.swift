//
//  WatchRecordingFigures.swift
//  OpenHikesShared
//
//  The four captioned figures under the clock on the watch's recording
//  screen, worded and formatted here rather than in the view that lays them
//  out.
//
//  ## A caption and its number are one fact
//
//  They were written side by side in the view and still disagreed: the
//  average was captioned "Pace" and formatted by
//  ``WidgetFormat/speed(metersPerSecond:locale:)``, so an hour's 5 km read
//  "5.0 km/h" under a word that means time per distance — 12 min/km. The
//  figure stays a speed and takes the phone's caption for it. The phone's
//  recording screen draws the same average, distance over the time spent
//  walking, as "Avg Speed" through the same formatter, and the share card
//  and the widget's chip say speed too; a watch that alone said pace would
//  be a second description of one number.
//
//  ## Why here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle, so the words and the rounding live in this package, where
//  `swift test` reaches them, and the watch's `RecordingFigures` only lays
//  them out. The caption is also what VoiceOver reads the figure by, so the
//  two cannot part company either.
//

import Foundation

/// The live figures on the watch's recording screen, each already captioned
/// and formatted for the locale in force.
public struct WatchRecordingFigures: Equatable, Sendable {
    /// One labelled number: the caption drawn under it, which is also its
    /// accessibility label, and the value.
    public struct Figure: Equatable, Sendable {
        public let title: String
        public let value: String
    }

    /// An em dash rather than a zero for a figure there is nothing to say
    /// about yet.
    static let missing = "—"

    public let distance: Figure
    public let climb: Figure
    public let averageSpeed: Figure
    public let heartRate: Figure

    public init(
        distanceMeters: Double,
        elevationGainMeters: Double,
        averageSpeedMetersPerSecond: Double?,
        heartRateBPM: Double?,
        locale: Locale = .current
    ) {
        distance = Figure(
            title: "Distance",
            value: WidgetFormat.length(meters: distanceMeters, locale: locale)
        )
        climb = Figure(
            title: "Climb",
            value: WidgetFormat.elevation(meters: elevationGainMeters, locale: locale)
        )
        averageSpeed = Figure(
            title: "Avg Speed",
            value: Self.speedText(averageSpeedMetersPerSecond, locale: locale)
        )
        heartRate = Figure(title: "Heart", value: Self.heartRateText(heartRateBPM))
    }

    /// A dash until the walk has both a distance and time spent walking to
    /// divide it by.
    private static func speedText(_ metersPerSecond: Double?, locale: Locale) -> String {
        guard let metersPerSecond else { return missing }
        return WidgetFormat.speed(metersPerSecond: metersPerSecond, locale: locale)
    }

    /// A dash rather than a zero while there is no reading: before HealthKit
    /// delivers a first sample, which without permission to read heart rate
    /// it never does. Drawn as 0 bpm, that would be the one number on this
    /// screen that alarms. A value that is not a finite number is no reading
    /// either, and `Int(_:)` would trap on it in the middle of a walk.
    private static func heartRateText(_ beats: Double?) -> String {
        guard let beats, beats.isFinite else { return missing }
        return "\(Int(beats.rounded()))"
    }
}
