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
        enum SubjectKind: String, Codable {
            case me = "me"
            case place = "place"
            case trail = "trail"
        }

        var symbolName: String
        var celsius: Double
        var conditionDescription: String
        var capturedAt: Date
        var latitude: Double
        var longitude: Double
        /// `nil` for a reading that was about the walker.
        var placeName: String?
        var subjectKind: SubjectKind
        var hikeID: UUID?
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
            hikeID: hikeID
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: SettingsKey.lastWeatherReading)
    }
}
