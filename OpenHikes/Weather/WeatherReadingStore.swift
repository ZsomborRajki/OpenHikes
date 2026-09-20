//
//  WeatherReadingStore.swift
//  OpenHikes
//
//  The last reading, carried across launches.
//
//  Not a cache in any useful sense — it holds exactly one reading and the app
//  refreshes it within seconds of launching. What it buys is the first of
//  those seconds. Without it a cold launch draws no badge at all until a
//  location arrives *and* a network round trip returns, which on a trailhead
//  with one bar is long enough that the feature reads as missing; with it the
//  badge is on screen immediately, dimmed by the same staleness rule that
//  governs a live reading, and is replaced the moment a real one lands.
//
//  **A blob this build cannot read is re-fetched, not migrated.** There is no
//  version field and there is deliberately no decoding branch for an older
//  shape: `load()` returns `nil`, the badge is absent for the few seconds
//  until WeatherKit answers, and the next save writes the current shape. That
//  is the whole cost of adding a field here, and it is the *Schema and
//  migration policy* answer rather than a shortcut — a reading is disposable
//  by construction, since the thing being stored is already stale enough to
//  dim within the hour.
//
//  Stored as one JSON blob in `UserDefaults` rather than in either SwiftData
//  store. It is device state, not a hike, so it does not belong in the
//  mirrored store; and it is one small value written a few times an hour,
//  which is what `UserDefaults` is for. ``HikeLocalState`` exists for the
//  device-specific things that are genuinely records.
//

import CoreLocation
import Foundation

/// A restored reading and the subject it was for.
nonisolated struct StoredWeatherReading: Sendable {
    let snapshot: WeatherSnapshot
    let subject: WeatherSubject
}

/// Reads and writes the one persisted reading.
///
/// Main-actor isolated by the module's default, which is where both its
/// callers are: ``WeatherManager`` loads once at init and saves on each
/// successful fetch. `UserDefaults` is not `Sendable`, so a `nonisolated`
/// version of this would have to launder it — and there is nothing here that
/// wants to run anywhere else.
final class WeatherReadingStore {
    /// The on-disk shape.
    ///
    /// The temperature is stored in Celsius as a plain `Double` rather than by
    /// encoding the `Measurement`, so the format does not depend on how
    /// Foundation happens to serialize a unit — this is read back by a future
    /// build of the app, and the badge converts to the reader's own units on
    /// the way to the screen anyway.
    private struct Payload: Codable {
        enum SubjectKind: String, Codable {
            case me = "me"
            case place = "place"
            case trail = "trail"
        }

        /// The rest of the reading, in fixed units for the reason the
        /// temperature is in Celsius: what is written here is read back by a
        /// later build, and the bytes must not depend on how Foundation
        /// happens to serialize a `Measurement` or on which unit the provider
        /// used that day.
        ///
        /// Its own type rather than twelve more fields alongside the nine
        /// above, so the two halves of this payload read as what they are: the
        /// subject and the reading.
        struct Conditions: Codable {
            var apparentCelsius: Double
            var dewPointCelsius: Double
            var humidity: Double
            var cloudCover: Double
            var pressureHectopascals: Double
            var uvIndexValue: Int
            /// Spelled by ``WeatherUVCategory``'s explicit raw values, which
            /// is why they are explicit.
            var uvCategory: WeatherUVCategory
            var visibilityMeters: Double
            var precipitationMillimetersPerHour: Double
            var windSpeedMetersPerSecond: Double
            var windDirectionDegrees: Double
            /// `nil` when there was no gust to report, which is a fact about
            /// the weather rather than about the format.
            var windGustMetersPerSecond: Double?

            /// The reading as the app holds it, rebuilt from the fixed units
            /// above.
            ///
            /// A member of this type rather than an initializer on
            /// ``WeatherConditions`` in this file, because ``Payload`` is
            /// private: an extension on another type cannot see it, and
            /// widening it to `fileprivate` to let one would be widening the
            /// storage format's visibility for the convenience of its own
            /// mapping.
            var restored: WeatherConditions {
                WeatherConditions(
                    apparentTemperature: Measurement(
                        value: apparentCelsius,
                        unit: UnitTemperature.celsius
                    ),
                    dewPoint: Measurement(value: dewPointCelsius, unit: UnitTemperature.celsius),
                    humidity: humidity,
                    cloudCover: cloudCover,
                    pressure: Measurement(
                        value: pressureHectopascals,
                        unit: UnitPressure.hectopascals
                    ),
                    uvIndex: WeatherUVIndex(value: uvIndexValue, category: uvCategory),
                    visibility: Measurement(value: visibilityMeters, unit: UnitLength.meters),
                    precipitationIntensity: Measurement(
                        value: precipitationMillimetersPerHour,
                        unit: UnitLength.millimeters
                    ),
                    wind: WeatherWind(
                        speed: Measurement(
                            value: windSpeedMetersPerSecond,
                            unit: UnitSpeed.metersPerSecond
                        ),
                        direction: Measurement(
                            value: windDirectionDegrees,
                            unit: UnitAngle.degrees
                        ),
                        gust: windGustMetersPerSecond.map { metersPerSecond in
                            Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
                        }
                    )
                )
            }

            init(_ conditions: WeatherConditions) {
                apparentCelsius = conditions.apparentTemperature.converted(to: .celsius).value
                dewPointCelsius = conditions.dewPoint.converted(to: .celsius).value
                humidity = conditions.humidity
                cloudCover = conditions.cloudCover
                pressureHectopascals = conditions.pressure.converted(to: .hectopascals).value
                uvIndexValue = conditions.uvIndex.value
                uvCategory = conditions.uvIndex.category
                visibilityMeters = conditions.visibility.converted(to: .meters).value
                precipitationMillimetersPerHour = conditions.precipitationIntensity
                    .converted(to: .millimeters).value
                windSpeedMetersPerSecond = conditions.wind.speed
                    .converted(to: .metersPerSecond).value
                windDirectionDegrees = conditions.wind.direction.converted(to: .degrees).value
                windGustMetersPerSecond = conditions.wind.gust?
                    .converted(to: .metersPerSecond).value
            }
        }

        /// One hour of the strip, in fixed units for the reason
        /// ``Conditions`` is: these bytes are read back by a later build.
        ///
        /// Bounded by ``WeatherHourlyPolicy/horizon`` before it ever reaches
        /// here — `.hourly` answers with days of data, and this is
        /// `UserDefaults`.
        struct Hour: Codable {
            var date: Date
            var symbolName: String
            var celsius: Double
            var precipitationChance: Double

            var restored: WeatherHourSummary {
                WeatherHourSummary(
                    date: date,
                    symbolName: symbolName,
                    temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
                    precipitationChance: precipitationChance
                )
            }

            init(_ hour: WeatherHourSummary) {
                date = hour.date
                symbolName = hour.symbolName
                celsius = hour.temperature.converted(to: .celsius).value
                precipitationChance = hour.precipitationChance
            }
        }

        /// One day of the week ahead, in fixed units for the reason
        /// ``Conditions`` is: these bytes are read back by a later build.
        ///
        /// Bounded by ``WeatherDailyPolicy/horizon`` before it ever reaches
        /// here — `.daily` answers with ten days, and this is `UserDefaults`.
        struct Day: Codable {
            var date: Date
            var symbolName: String
            var highCelsius: Double
            var lowCelsius: Double
            var precipitationChance: Double

            var restored: WeatherDaySummary {
                WeatherDaySummary(
                    date: date,
                    symbolName: symbolName,
                    highTemperature: Measurement(
                        value: highCelsius,
                        unit: UnitTemperature.celsius
                    ),
                    lowTemperature: Measurement(
                        value: lowCelsius,
                        unit: UnitTemperature.celsius
                    ),
                    precipitationChance: precipitationChance
                )
            }

            init(_ day: WeatherDaySummary) {
                date = day.date
                symbolName = day.symbolName
                highCelsius = day.highTemperature.converted(to: .celsius).value
                lowCelsius = day.lowTemperature.converted(to: .celsius).value
                precipitationChance = day.precipitationChance
            }
        }

        /// The day's light, in fixed units for the reason ``Conditions`` is:
        /// these bytes are read back by a later build.
        ///
        /// Every field optional, because every one of them genuinely is —
        /// see ``WeatherDaylight``, whose header explains why a missing
        /// sunset is a fact about the Arctic rather than a failure.
        struct Daylight: Codable {
            var sunrise: Date?
            var sunset: Date?
            var civilDusk: Date?
            var highCelsius: Double?
            var lowCelsius: Double?

            var restored: WeatherDaylight {
                WeatherDaylight(
                    sunrise: sunrise,
                    sunset: sunset,
                    civilDusk: civilDusk,
                    highTemperature: highCelsius.map { celsius in
                        Measurement(value: celsius, unit: UnitTemperature.celsius)
                    },
                    lowTemperature: lowCelsius.map { celsius in
                        Measurement(value: celsius, unit: UnitTemperature.celsius)
                    }
                )
            }

            init(_ daylight: WeatherDaylight) {
                sunrise = daylight.sunrise
                sunset = daylight.sunset
                civilDusk = daylight.civilDusk
                highCelsius = daylight.highTemperature?.converted(to: .celsius).value
                lowCelsius = daylight.lowTemperature?.converted(to: .celsius).value
            }
        }

        /// The alert state, flattened so the stored bytes do not depend on
        /// how Foundation happens to encode an enum with an associated value.
        ///
        /// Two fields rather than one, because the three-way state needs them:
        /// ``isWatched`` is whether WeatherKit has an alerting partner for the
        /// place at all, and ``summaries`` is what it said. Watched with an
        /// empty list is the all-clear; unwatched is nobody looking. Collapsing
        /// them would lose exactly the distinction ``WeatherAlerts`` exists
        /// for — see that file's header.
        struct Alerts: Codable {
            var isWatched: Bool
            var summaries: [WeatherAlertSummary]

            var restored: WeatherAlerts {
                guard isWatched else { return .unavailable }
                return summaries.isEmpty ? .clear : .active(summaries)
            }

            init(_ alerts: WeatherAlerts) {
                switch alerts {
                case .unavailable:
                    isWatched = false
                    summaries = []
                case .clear:
                    isWatched = true
                    summaries = []
                case .active(let active):
                    isWatched = true
                    summaries = active
                }
            }
        }

        var symbolName: String
        var celsius: Double
        var conditionDescription: String
        var capturedAt: Date
        var latitude: Double
        var longitude: Double
        /// `nil` for a reading that was about the hiker.
        var placeName: String?
        var subjectKind: SubjectKind
        var hikeID: UUID?
        /// Non-optional, which is what makes a blob written before these
        /// existed fail to decode — see this file's header for why that is the
        /// intended outcome and not a hazard.
        var conditions: Conditions
        /// Non-optional for the same reason ``conditions`` is, and with the
        /// same consequence: the blob written by the build before this field
        /// existed fails to decode once and is replaced by the next successful
        /// fetch, seconds after launch. An *empty* array is still a valid
        /// value, and means the provider had no hourly data for the point.
        var hourly: [Hour]
        /// Non-optional for the reason ``hourly`` is, with one wrinkle worth
        /// writing down. A blob written by the build that asked for `.daily`
        /// only to read its first day has no `days` key, and an *optional*
        /// field would restore it as an empty week — which reads as "the
        /// provider has no daily forecast for this place" and is not what
        /// happened. Non-optional, that blob fails to decode, the badge is
        /// absent for the few seconds until the next fetch, and nothing ever
        /// claims a fact about the weather that no response supports. An empty
        /// array *written by this build* is still a valid value and does mean
        /// the provider had nothing.
        var days: [Day]
        /// **Optional, unlike ``conditions`` and ``hourly``**, and that is the
        /// reset policy rather than an inconsistency. Those two are
        /// non-optional so a blob written before they existed fails to decode
        /// and is replaced within seconds of launch — which is right, because
        /// a reading without conditions is wrong. A reading without daylight
        /// is merely older: it draws every row it drew before and gains the
        /// daylight section on the next successful fetch. Failing the decode
        /// for it would throw away a perfectly good reading to hurry up a
        /// field nothing depends on.
        var daylight: Daylight?
        /// Optional for the reason ``daylight`` is, and for one more that is
        /// specific to it: the restored value's own ``WeatherAlerts/unavailable``
        /// means *this region has no alerting partner*, and a blob written by
        /// a build that never asked for `.alerts` must not decode as that. The
        /// optional's `nil` is "this build did not ask"; `isWatched == false`
        /// is "nobody is watching here". Only one of those is a fact about the
        /// weather.
        var alerts: Alerts?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StoredWeatherReading? {
        guard let data = defaults.data(forKey: SettingsKey.lastWeatherReading),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let coordinate = CLLocationCoordinate2D(
            latitude: payload.latitude,
            longitude: payload.longitude
        )
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let snapshot = WeatherSnapshot(
            symbolName: payload.symbolName,
            temperature: Measurement(value: payload.celsius, unit: UnitTemperature.celsius),
            conditionDescription: payload.conditionDescription,
            capturedAt: payload.capturedAt,
            conditions: payload.conditions.restored,
            hourly: payload.hourly.map(\.restored),
            days: payload.days.map(\.restored),
            daylight: payload.daylight?.restored,
            alerts: payload.alerts?.restored
        )
        let subject: WeatherSubject
        switch payload.subjectKind {
        case .me:
            subject = .me(coordinate)
        case .place:
            guard let name = payload.placeName else { return nil }
            subject = .place(coordinate, name: name)
        case .trail:
            guard let name = payload.placeName, let hikeID = payload.hikeID else { return nil }
            subject = .trail(coordinate, hikeID: hikeID, name: name)
        }
        return StoredWeatherReading(snapshot: snapshot, subject: subject)
    }

    func save(snapshot: WeatherSnapshot, subject: WeatherSubject) {
        let coordinate = subject.coordinate
        let subjectKind: Payload.SubjectKind
        let hikeID: UUID?
        switch subject {
        case .me:
            subjectKind = .me
            hikeID = nil
        case .place:
            subjectKind = .place
            hikeID = nil
        case .trail(_, let id, _):
            subjectKind = .trail
            hikeID = id
        }
        let payload = Payload(
            symbolName: snapshot.symbolName,
            celsius: snapshot.temperature.converted(to: .celsius).value,
            conditionDescription: snapshot.conditionDescription,
            capturedAt: snapshot.capturedAt,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: subject.placeName,
            subjectKind: subjectKind,
            hikeID: hikeID,
            conditions: Payload.Conditions(snapshot.conditions),
            hourly: snapshot.hourly.map(Payload.Hour.init),
            days: snapshot.days.map(Payload.Day.init),
            daylight: snapshot.daylight.map(Payload.Daylight.init),
            alerts: snapshot.alerts.map(Payload.Alerts.init)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: SettingsKey.lastWeatherReading)
    }
}
