//
//  WeatherReadingFetching.swift
//  OpenHikes
//
//  The round trip behind the badge, on the far side of a seam.
//
//  ``WeatherManager/update(for:)`` decides what the badge, the stored reading
//  and the widget say once a request comes back, and it used to ask
//  `WeatherService.shared` itself, which left that decision out of every
//  suite's reach. None of WeatherKit's answers has a public initializer, and
//  the real call is a metered request against an entitlement — see *Deliberate
//  test seams* in `AGENTS.md`.
//
//  So the seam sits at ``WeatherSnapshot``, the value that exists because a
//  suite can stand one up, and what stays out of reach is only the mapping
//  below: the one place the four datasets are read.
//

import CoreLocation
import WeatherKit

/// Turns a coordinate into a reading of the weather there.
@MainActor
protocol WeatherReadingFetching {
    /// The reading for `coordinate`, or whatever the request threw.
    func reading(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot
}

/// WeatherKit's own answer.
struct WeatherKitReadings: WeatherReadingFetching {
    func reading(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // One round trip, four datasets. `weather(for:including:)` is
        // variadic and answers all of them from the same request, so the
        // strip, the week, the daylight row and the alerts cost what the
        // badge was already spending — see ``WeatherHourSummary``,
        // ``WeatherDaySummary``, ``WeatherDaylight`` and
        // ``WeatherAlerts``.
        let (reading, forecast, daily, alerts) = try await WeatherService.shared.weather(
            for: location,
            including: .current,
            .hourly,
            .daily,
            .alerts
        )
        return WeatherSnapshot(
            reading,
            hourly: WeatherHourSummary.summaries(
                from: forecast,
                notBefore: reading.metadata.date
            ),
            // The next two are the same ten days read twice: the week a
            // walk is chosen from, and the one day's sun that ends the
            // walk already chosen. Both are anchored against the reading's
            // own date rather than `Date.now`, for the reason
            // ``WeatherSnapshot/capturedAt`` gives: WeatherKit serves
            // cached payloads, and a response that arrives at 00:05 may be
            // a reading taken yesterday.
            days: WeatherDaySummary.summaries(
                from: daily,
                notBefore: reading.metadata.date
            ),
            daylight: WeatherDaylight.forDay(
                of: reading.metadata.date,
                in: daily
            ),
            // The `nil` is carried rather than defaulted away: it is the
            // difference between nobody watching this place and nothing to
            // report, and it is the one this app must not get wrong.
            alerts: WeatherAlerts(alerts)
        )
    }
}
