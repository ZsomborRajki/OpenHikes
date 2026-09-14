import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// The other half of "I rarely see the badge": a cold launch used to draw
/// nothing until a location arrived *and* a network round trip returned.
@MainActor
@Suite("Weather reading store")
struct WeatherReadingStoreTests {
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let capturedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// Every measurement a different number, in a different unit from the one
    /// it is stored in wherever that is possible.
    ///
    /// Both halves are the point. Distinct values catch a mapping that crossed
    /// two fields over, which is the failure this round trip exists for and
    /// the one that a fixture of round numbers would hide. Unconverted units
    /// catch the other half: the payload holds Celsius, metres, hectopascals
    /// and metres per second, so a field written without its conversion comes
    /// back as kilometres per hour pretending to be metres per second.
    private let conditions = WeatherConditions(
        apparentTemperature: Measurement(value: 9, unit: .celsius),
        dewPoint: Measurement(value: 3, unit: .celsius),
        humidity: 0.81,
        cloudCover: 0.37,
        pressure: Measurement(value: 1007, unit: .hectopascals),
        uvIndex: WeatherUVIndex(value: 6, category: .high),
        visibility: Measurement(value: 12, unit: .kilometers),
        precipitationIntensity: Measurement(value: 2.5, unit: .millimeters),
        wind: WeatherWind(
            speed: Measurement(value: 18, unit: .kilometersPerHour),
            direction: Measurement(value: 225, unit: .degrees),
            gust: Measurement(value: 31, unit: .kilometersPerHour)
        )
    )

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "weather-store-\(UUID().uuidString)"))
    }

    private func snapshot(celsius: Double) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt,
            conditions: conditions
        )
    }

    @Test("nothing stored restores nothing")
    func emptyStoreRestoresNothing() throws {
        #expect(WeatherReadingStore(defaults: try makeDefaults()).load() == nil)
    }

    @Test("a saved reading comes back whole")
    func roundTripsAReading() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let saved = snapshot(celsius: 4)
        store.save(snapshot: saved, subject: .place(budapest, name: "Budapest"))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot == saved)
        #expect(restored.subject == .place(budapest, name: "Budapest"))
    }

    @Test("a selected hike stays a trail across launches")
    func roundTripsATrailSubject() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let saved = snapshot(celsius: 4)
        let subject = WeatherSubject.trail(
            budapest,
            hikeID: UUID(),
            name: "Pilis Loop"
        )
        store.save(snapshot: saved, subject: subject)

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot == saved)
        #expect(restored.subject == subject)
    }

    @Test("a reading without a subject kind is discarded")
    func missingSubjectKindIsRefused() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        store.save(snapshot: snapshot(celsius: 4), subject: .place(budapest, name: "Budapest"))
        let data = try #require(defaults.data(forKey: SettingsKey.lastWeatherReading))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "subjectKind")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: SettingsKey.lastWeatherReading)

        #expect(store.load() == nil)
    }

    /// The age is what makes a restored reading honest — it is drawn dimmed by
    /// the same rule a live one is — so the capture time has to survive the
    /// round trip exactly. Stamping it on load would present last night's
    /// weather as current.
    @Test("a restored reading keeps its original age")
    func keepsCaptureTime() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults).save(
            snapshot: snapshot(celsius: 4),
            subject: .me(budapest)
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot.capturedAt == capturedAt)
        #expect(restored.snapshot.isStale(asOf: .now), "a reading this old is not current")
    }

    /// A reading about the hiker comes back as one, not as a place with no
    /// name — the badge draws its "here" form off exactly this.
    @Test("a reading about the hiker restores without a place name")
    func restoresTheHikerWithoutAName() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults).save(
            snapshot: snapshot(celsius: 4),
            subject: .me(budapest)
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.subject.placeName == nil)
    }

    /// A manager built on a store that has something restores straight into a
    /// reading, which is the whole point: the badge is on screen before the
    /// first network call rather than half a minute after it.
    @Test("a manager restores its badge from the store at launch")
    func managerRestoresAtLaunch() throws {
        let defaults = try makeDefaults()
        let saved = snapshot(celsius: 4)
        WeatherReadingStore(defaults: defaults).save(
            snapshot: saved,
            subject: .place(budapest, name: "Budapest")
        )

        let manager = WeatherManager(store: WeatherReadingStore(defaults: defaults))
        #expect(manager.state == .reading(saved, subject: .place(budapest, name: "Budapest")))
    }

    /// Every one of the nine, across a launch.
    ///
    /// Asserted field by field rather than through the `Equatable` conformance
    /// the round-trip test above already leans on, because that conformance is
    /// exactly what a crossed pair of fields would satisfy: two measurements
    /// swapped between `apparentTemperature` and `dewPoint` are still equal to
    /// themselves. The comparisons are made in a unit the payload does *not*
    /// store, so a missing conversion fails here rather than travelling.
    @Test("the whole reading survives a launch, not just its temperature")
    func roundTripsEveryReading() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(celsius: 4), subject: .place(budapest, name: "Budapest"))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load()).snapshot.conditions

        #expect(restored.apparentTemperature.converted(to: .fahrenheit).value.rounded() == 48)
        #expect(restored.dewPoint.converted(to: .celsius).value == 3)
        #expect(restored.humidity == 0.81)
        #expect(restored.cloudCover == 0.37)
        #expect(restored.pressure.converted(to: .hectopascals).value == 1007)
        #expect(restored.uvIndex == WeatherUVIndex(value: 6, category: .high))
        #expect(restored.visibility.converted(to: .kilometers).value == 12)
        #expect(restored.precipitationIntensity.converted(to: .millimeters).value == 2.5)
        #expect(restored.wind.speed.converted(to: .kilometersPerHour).value.rounded() == 18)
        #expect(restored.wind.direction.converted(to: .degrees).value == 225)
        let gust = try #require(restored.wind.gust)
        #expect(gust.converted(to: .kilometersPerHour).value.rounded() == 31)
    }

    /// A still day has no gust, and the absence has to survive too.
    ///
    /// The cheap bug here is an optional written as zero, which reads back as
    /// a row claiming the wind is gusting to nothing.
    @Test("no gust stays no gust")
    func roundTripsAnAbsentGust() throws {
        let defaults = try makeDefaults()
        var still = conditions
        still.wind.gust = nil
        let saved = WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: 4, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt,
            conditions: still
        )
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: saved, subject: .place(budapest, name: "Budapest"))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot.conditions.wind.gust == nil)
        #expect(restored.snapshot == saved)
    }

    /// A blob written before the reading carried these fields is discarded
    /// rather than half-read.
    ///
    /// This is the decision rather than an accident, and it is the whole cost
    /// of adding a field to this payload: one launch draws no badge for the
    /// few seconds until WeatherKit answers, and the next save writes the
    /// current shape. The alternative — optional fields and a decoding branch
    /// — is what *Schema and migration policy* refuses while installs are
    /// disposable, and it would keep a compatibility shim alive forever for a
    /// value that dims within the hour.
    @Test("a reading stored before the conditions existed is dropped, not patched")
    func readingWithoutConditionsIsDiscarded() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(celsius: 4), subject: .place(budapest, name: "Budapest"))
        let data = try #require(defaults.data(forKey: SettingsKey.lastWeatherReading))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "conditions")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: SettingsKey.lastWeatherReading
        )

        #expect(WeatherReadingStore(defaults: defaults).load() == nil)
    }
}
