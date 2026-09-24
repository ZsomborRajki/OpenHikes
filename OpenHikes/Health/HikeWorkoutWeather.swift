//
//  HikeWorkoutWeather.swift
//  OpenHikes
//
//  The weather a finished walk is written to Health with, and — mostly — when
//  there is none to write.
//
//  ## Why the rule is strict
//
//  Health draws a workout's temperature and humidity as facts about that
//  workout. The app always has *a* reading, because the badge keeps its last
//  one and restores it across launches; what it does not always have is one
//  about this walk. A stale reading stamped onto a workout is worse than no
//  weather at all, because nothing in Health says how old it was — the badge
//  dims an old reading for exactly that reason, and a workout has no way to
//  be dimmed.
//
//  So a reading is attached only when both of these hold:
//
//  - **It is about the hiker.** A recording pins the badge to
//    ``WeatherSubject/me`` for its whole length — see ``WeatherFocus`` — so a
//    reading about a searched city or a selected trail is a reading about
//    somewhere else, however recent.
//  - **It was taken during the walk**, give or take the window the badge
//    dims at (``WeatherPollingPolicy/stalenessInterval``). The poll loop
//    refreshes a pinned subject while the recording runs, so an ordinary walk
//    has one; a walk recorded with no network has none, and gets none.
//
//  ## What is not attached
//
//  `HKMetadataKeyWeatherCondition`. WeatherKit's condition enum is not kept on
//  ``WeatherSnapshot`` — only its localized description and SF Symbol are —
//  and mapping either of those onto `HKWeatherCondition` would be guessing at a
//  table from its rendering. The temperature and the humidity are measured
//  quantities and cross unchanged.
//

import Foundation

/// The two weather quantities a workout carries.
nonisolated struct HikeWorkoutWeather: Equatable, Sendable {
    let temperature: Measurement<UnitTemperature>
    /// Relative humidity, 0...1 — the scale ``WeatherConditions/humidity``
    /// uses and the one HealthKit's percent unit expects.
    let humidity: Double

    /// The reading a walk from `startedAt` to `endedAt` may carry, or `nil`
    /// when `state` holds none that is about it. See the file header for the
    /// two conditions.
    ///
    /// `endedAt` is when the walk stopped by the clock, pauses included — not
    /// start plus moving time. The poll loop keeps refreshing through a pause,
    /// so the reading a walk ends with is one taken near the stop.
    init?(
        state: WeatherBadgeState,
        walkFrom startedAt: Date,
        to endedAt: Date,
        policy: WeatherPollingPolicy = .standard
    ) {
        guard case .reading(let snapshot, subject: .me) = state else { return nil }
        let window = policy.stalenessInterval
        let capturedAt = snapshot.capturedAt
        guard capturedAt >= startedAt.addingTimeInterval(-window),
              capturedAt <= endedAt.addingTimeInterval(window) else { return nil }
        let relative = snapshot.conditions.humidity
        guard snapshot.temperature.value.isFinite,
              relative.isFinite, (0...1).contains(relative) else { return nil }
        temperature = snapshot.temperature
        humidity = relative
    }
}
