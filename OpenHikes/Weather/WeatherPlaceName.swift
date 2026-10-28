//
//  WeatherPlaceName.swift
//  OpenHikes
//
//  What to call the place a forecast is for.
//
//  The detail sheet used to be headed with the ``WeatherSubject``'s own name,
//  which for a selected route is the *hike's* title — "Morning loop", "Pilis
//  Ridge", whatever the hiker called it. That names the thing they tapped
//  rather than the thing the forecast describes, and on an imported or a
//  community trail it can be a name they have never seen attached to a place.
//  A forecast is for somewhere, and the sheet is the one screen with room to
//  say where.
//
//  So a trail's reading is headed with the **city** its anchor falls in, which
//  is the answer to the question a hiker actually has — *where is this
//  forecast from* — and the one a weather app would give.
//
//  ## And what day and time it is there
//
//  The same answer carries the place's time zone, which WeatherKit does not:
//  a `DayWeather` is dated at midnight *there*, and its weekday names, hourly
//  labels and daylight clock times belong to that zone — Tokyo's Friday,
//  formatted in Berlin, begins on Thursday afternoon. So a searched place is looked up too,
//  for its zone alone, while keeping the name the hiker searched for; and
//  `me` is not, because *here* is the reader's own zone. Which day is today,
//  and which day's sun ends a walk, need no zone at all — see
//  ``WeatherForecastDay`` — so a launch with no geocoder draws the weekday
//  names and clock times in the reader's zone, as it always did.
//
//  ## Why this is a seam
//
//  For the reason every injected dependency in this repository is one — see
//  *Deliberate test seams* in `AGENTS.md`. It reaches the network, so a
//  suite using the real thing would geocode from a test run, on somebody's
//  rate limit, and get a different answer depending on where the machine is.
//  ``WeatherManager``'s parameter defaults to `nil`, and the UI-testing
//  composition leaves it that way: a sheet with no namer is headed exactly as
//  it was before this file existed.
//
//  ## Why it is main-actor rather than `@concurrent`
//
//  Unlike ``WeatherManager/update(for:)``, this one cannot choose:
//  `MKReverseGeocodingRequest.mapItems` is declared `NS_SWIFT_UI_ACTOR` in the
//  SDK, so MapKit delivers its answer on the main actor whatever the caller
//  does — and below iOS 26, where ``ReverseGeocode`` asks `CLGeocoder`
//  instead, that calls back on the main thread too. The work itself is a round
//  trip in another process; what arrives here is a string. ``GeocodedAreaNames`` says the same thing for the same reason
//  — two small geocoders rather than one shared abstraction, because they
//  cancel against different questions and cache on different keys.
//

import CoreLocation
import Foundation
import MapKit
import os

/// What the geocoder said about the place a forecast is for.
nonisolated struct WeatherPlaceDescription: Equatable, Sendable {
    /// The city the coordinate falls in, `nil` on open hillside.
    var cityName: String?
    /// The zone the forecast's clock times and calendar days belong to.
    var timeZone: TimeZone?
}

/// Turns the coordinate a forecast was fetched for into somewhere to call it.
@MainActor
protocol WeatherPlaceNaming: AnyObject {
    /// The city `coordinate` falls in and its time zone, or `nil` when there
    /// is nothing to say about it. Both are niceties, so every failure — no
    /// network, no result, a cancelled request — is the same answer.
    func place(at coordinate: CLLocationCoordinate2D) async -> WeatherPlaceDescription?
}

/// MapKit's own answer, which is the same one the search field's suggestions
/// come from.
@MainActor
final class GeocodedWeatherPlaceNames: WeatherPlaceNaming {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Weather")

    /// The last request, cancelled when another is made.
    ///
    /// One at a time because there is only ever one title: a hiker who opens
    /// the sheet, dismisses it and selects another trail wants the second
    /// name, and the first request's answer would otherwise be free to land
    /// after it.
    private var request: ReverseGeocode?

    func place(at coordinate: CLLocationCoordinate2D) async -> WeatherPlaceDescription? {
        request?.cancel()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let pending = ReverseGeocode(location: location) else { return nil }
        request = pending
        do {
            let items = try await pending.mapItems
            guard request === pending else { return nil }
            request = nil
            // The city and nothing else — deliberately *not*
            // ``GeocodedAreaNames``' fallback to the map item's own name. That
            // fallback exists so a header always says something; here the
            // fallback is the hike's own title, which is already better than a
            // street or a summit would be. A trail anchored on open
            // hillside has no city, and saying so with a `nil` one is how
            // the sheet knows to keep the name it had — while its zone is
            // still worth having.
            guard let item = items.first else { return nil }
            return WeatherPlaceDescription(
                cityName: item.cityName,
                timeZone: item.timeZone
            )
        } catch {
            // Logged and no more. A sheet headed with the hike's name instead
            // of the valley's is not something a hiker can act on, and there
            // is nowhere on this screen that a failed geocode belongs.
            Self.logger.debug(
                "Naming a forecast's place failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
