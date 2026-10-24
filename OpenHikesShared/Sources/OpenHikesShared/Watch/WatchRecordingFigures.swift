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
//  ## A heart rate has an age
//
//  The workout builder calls back only when HealthKit collects a sample, and
//  its statistics cover the whole workout, so its most recent quantity is
//  the last reading ever taken and never goes back to nothing. With the band
//  loosened or the watch off the wrist, the last number stayed up beside a
//  clock and a distance that kept moving, and read exactly like a live one
//  (#1024). So the reading carries the time it was sampled, and a reading
//  older than ``heartRateFreshness`` is no reading: the dash, as before the
//  first sample. Since a stale reading by definition brings no callback,
//  ``heartRateRedraws(sampledAt:)`` names the moments the screen has to be
//  drawn again without one.
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
        elevationGainMeters: Double?,
        averageSpeedMetersPerSecond: Double?,
        heartRateBPM: Double?,
        heartRateSampledAt: Date?,
        now: Date,
        locale: Locale = .current
    ) {
        distance = Figure(
            title: "Distance",
            value: WidgetFormat.length(meters: distanceMeters, locale: locale)
        )
        climb = Figure(
            title: "Climb",
            value: Self.climbText(elevationGainMeters, locale: locale)
        )
        averageSpeed = Figure(
            title: "Avg Speed",
            value: Self.speedText(averageSpeedMetersPerSecond, locale: locale)
        )
        heartRate = Figure(
            title: "Heart",
            value: Self.heartRateText(heartRateBPM, sampledAt: heartRateSampledAt, now: now)
        )
    }

    /// A dash until the walk has two trusted heights to compare, as on the
    /// phone. A level walk that has them reads 0 m, because by then it is a
    /// measurement; before them, and all through a walk whose heights
    /// `AltitudePolicy` refuses, there is nothing measured to round to zero.
    private static func climbText(_ meters: Double?, locale: Locale) -> String {
        guard let meters else { return missing }
        return WidgetFormat.elevation(meters: meters, locale: locale)
    }

    /// A dash until the walk has both a distance and time spent walking to
    /// divide it by.
    private static func speedText(_ metersPerSecond: Double?, locale: Locale) -> String {
        guard let metersPerSecond else { return missing }
        return WidgetFormat.speed(metersPerSecond: metersPerSecond, locale: locale)
    }

    /// How long a heart-rate sample is still the hiker's heart rate. A
    /// workout session samples every few seconds, so a minute without one is
    /// a sensor that has stopped reading; the margin beyond that is for Low
    /// Power Mode, which samples less often and should not flicker a dash
    /// between readings.
    public static let heartRateFreshness: TimeInterval = 120

    /// When the heart figure has to be drawn: at the sample, and again the
    /// moment it goes stale, which no callback announces. Handed to an
    /// explicit timeline, the first date is in the past, so the screen's
    /// first pass is judged at the sample and the second at its expiry.
    public static func heartRateRedraws(sampledAt: Date?) -> [Date] {
        guard let sampledAt else { return [] }
        return [sampledAt, sampledAt.addingTimeInterval(heartRateFreshness)]
    }

    /// A dash rather than a zero while there is no reading: before HealthKit
    /// delivers a first sample, which without permission to read heart rate
    /// it never does. Drawn as 0 bpm, that would be the one number on this
    /// screen that alarms. A value that is not a finite number is no reading
    /// either, and `Int(_:)` would trap on it in the middle of a walk. Nor is
    /// one without the time it was taken, or one taken longer ago than
    /// ``heartRateFreshness``: the sensor has stopped, and its last number is
    /// not the heart rate now.
    private static func heartRateText(_ beats: Double?, sampledAt: Date?, now: Date) -> String {
        guard let beats, beats.isFinite, let sampledAt,
              now.timeIntervalSince(sampledAt) < heartRateFreshness
        else { return missing }
        return "\(Int(beats.rounded()))"
    }
}
