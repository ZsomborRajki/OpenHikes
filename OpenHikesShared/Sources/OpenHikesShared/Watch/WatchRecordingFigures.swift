//
//  WatchRecordingFigures.swift
//  OpenHikesShared
//
//  The four captioned figures under the clock on the watch's recording
//  screen, captioned and formatted here rather than in the view that lays
//  them out.
//
//  ## A caption and its number are one fact
//
//  They were written side by side in the view and still disagreed: the
//  average was captioned "Pace" and formatted by
//  ``WidgetFormat/speed(metersPerSecond:locale:)``, so an hour's 5 km read
//  "5.0 km/h" under a word that means time per distance — 12 min/km. The
//  figure stays a speed and takes the phone's caption for it. The phone's
//  recording screen draws the same average, distance over the time the
//  recording ran with its pauses taken out, as "Avg Speed" through the same
//  formatter, and the share card and the widget's chip say speed too; a
//  watch that alone said pace would be a second description of one number.
//
//  ## Why here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle, so which caption each figure takes, and the rounding, live in
//  this package, where `swift test` reaches them, and the watch target
//  only words the captions and lays them out. The caption is also what
//  VoiceOver reads the figure by — in full where the tile shortens it, as
//  "Average Speed" for "Avg Speed" — and the watch target words both from
//  the one caption, so the two cannot part company either.
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
//  So it is the one figure that can change with no fix or sample behind the
//  change, and ``heartRate(bpm:sampledAt:now:)`` builds it apart from the
//  other three: the screen draws it in a view of its own, where a sample or
//  the expiry redraws that figure and not the panel.
//

import Foundation

/// The live figures on the watch's recording screen, each already captioned
/// and formatted for the locale in force.
public struct WatchRecordingFigures: Equatable, Sendable {
    /// One labelled number: the caption drawn under it, which also names it
    /// to VoiceOver, and the value.
    public struct Figure: Equatable, Sendable {
        public let caption: Caption
        public let value: String
    }

    /// Which caption a figure is drawn under and read out by.
    ///
    /// The words themselves are the watch target's, in
    /// `WatchRecordingFigures+Caption.swift`, because only an app target's
    /// build extracts strings into its String Catalog (*Layout and targets*
    /// in the repository instructions). A literal written here was drawn but
    /// reached no catalog at all, so `sync-string-catalogs.sh --check` could
    /// never notice it missing (#1028).
    public enum Caption: Equatable, Sendable {
        case distance
        case climb
        case averageSpeed
        case heartRate
    }

    /// An em dash rather than a zero for a figure there is nothing to say
    /// about yet.
    static let missing = "—"

    public let distance: Figure
    public let climb: Figure
    public let averageSpeed: Figure

    public init(
        distanceMeters: Double,
        elevationGainMeters: Double?,
        averageSpeedMetersPerSecond: Double?,
        locale: Locale = .current
    ) {
        distance = Figure(
            caption: .distance,
            value: WidgetFormat.length(meters: distanceMeters, locale: locale)
        )
        climb = Figure(
            caption: .climb,
            value: Self.climbText(elevationGainMeters, locale: locale)
        )
        averageSpeed = Figure(
            caption: .averageSpeed,
            value: Self.speedText(averageSpeedMetersPerSecond, locale: locale)
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

    /// A dash until the walk has both a distance and time on its clock to
    /// divide it by — see ``WatchWalkAccumulator/averageSpeedMetersPerSecond``.
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
    /// first pass is judged at the sample and the next at its expiry.
    ///
    /// It ends on a date that never comes, because an explicit timeline
    /// never draws its last date. Measured on a Mac stand-in: a schedule of a
    /// second ago and half a second ahead drew once, at a second ago, and
    /// never again, and one wholly in the past drew the date before its last,
    /// where the documentation says the last. With the expiry last, a reading
    /// was judged at its sample time for as long as it stayed up. Followed by
    /// `distantFuture`, the expiry is drawn on time and stays drawn, under the
    /// documented behavior and the measured one alike.
    public static func heartRateRedraws(sampledAt: Date?) -> [Date] {
        guard let sampledAt else { return [] }
        return [sampledAt, sampledAt.addingTimeInterval(heartRateFreshness), .distantFuture]
    }

    /// The heart figure as it reads at `now`, for the last reading and the
    /// time it was sampled.
    public static func heartRate(bpm: Double?, sampledAt: Date?, now: Date) -> Figure {
        Figure(caption: .heartRate, value: heartRateText(bpm, sampledAt: sampledAt, now: now))
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
