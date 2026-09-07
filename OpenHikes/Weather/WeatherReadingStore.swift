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
        var symbolName: String
        var celsius: Double
        var conditionDescription: String
        var capturedAt: Date
        var latitude: Double
        var longitude: Double
        /// `nil` for a reading that was about the walker.
        var placeName: String?
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
            capturedAt: payload.capturedAt
        )
        // A restored `trail` comes back as a `place` carrying the same name.
        // The two draw identically — a name and a temperature — and the
        // distinction only governs whether the subject follows the walker,
        // which a reading that is about to be replaced has no use for. The
        // alternative is persisting a hike ID that may since have been
        // deleted, to reconstruct a case that lives for one second.
        let subject: WeatherSubject = payload.placeName
            .map { .place(coordinate, name: $0) }
            ?? .me(coordinate)
        return StoredWeatherReading(snapshot: snapshot, subject: subject)
    }

    func save(snapshot: WeatherSnapshot, subject: WeatherSubject) {
        let coordinate = subject.coordinate
        let payload = Payload(
            symbolName: snapshot.symbolName,
            celsius: snapshot.temperature.converted(to: .celsius).value,
            conditionDescription: snapshot.conditionDescription,
            capturedAt: snapshot.capturedAt,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeName: subject.placeName
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: SettingsKey.lastWeatherReading)
    }
}
