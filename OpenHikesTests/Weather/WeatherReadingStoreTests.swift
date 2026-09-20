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

    /// A manager asked to restore puts the stored reading on the badge, which
    /// is the whole point: the badge is on screen before the first network
    /// call rather than half a minute after it.
    @Test("a manager restores its badge from the store")
    func managerRestoresOnRequest() throws {
        let defaults = try makeDefaults()
        let saved = snapshot(celsius: 4)
        WeatherReadingStore(defaults: defaults).save(
            snapshot: saved,
            subject: .place(budapest, name: "Budapest")
        )

        let manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        manager.restoreLastReading()
        #expect(manager.state == .reading(saved, subject: .place(budapest, name: "Budapest")))
    }

    /// Building the manager reads nothing.
    ///
    /// The assertion that keeps the decode off the composition path, which is
    /// where it cost 18-27 ms of the main thread before the first frame. A
    /// restore moved back into `init` fails here rather than silently putting
    /// the time back.
    @Test("building a manager does not touch the store")
    func buildingDoesNotRestore() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults).save(
            snapshot: snapshot(celsius: 4),
            subject: .place(budapest, name: "Budapest")
        )

        let manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        #expect(manager.state == .idle)
    }

    /// The restore is a floor under an empty badge, not something that
    /// overwrites what is already on it.
    ///
    /// The deferral opened a race the old initializer could not have: the
    /// restore now runs after the first frame, so a focus — or the UI-test
    /// fixture — can beat it to the badge. Last night's reading must not land
    /// on top of one that arrived since.
    @Test("a restore never displaces a reading already on the badge")
    func restoreYieldsToWhatIsAlreadyShowing() throws {
        let defaults = try makeDefaults()
        let stored = snapshot(celsius: 4)
        WeatherReadingStore(defaults: defaults).save(
            snapshot: stored,
            subject: .place(budapest, name: "Budapest")
        )
        let manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        let france = WeatherSubject.place(
            CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
            name: "Chamonix"
        )
        manager.focus(on: france, willRequest: true)

        manager.restoreLastReading()

        #expect(manager.state == .loading(france))
    }

    /// And it seeds the cache whether or not it took the badge, so going back
    /// to the restored subject answers from memory rather than from the
    /// network.
    @Test("a restore that yielded still primes the subject it was for")
    func restoreSeedsTheCacheEvenWhenItYields() throws {
        let defaults = try makeDefaults()
        let stored = snapshot(celsius: 4)
        let budapestSubject = WeatherSubject.place(budapest, name: "Budapest")
        WeatherReadingStore(defaults: defaults).save(
            snapshot: stored,
            subject: budapestSubject
        )
        let manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        manager.focus(
            on: .place(
                CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
                name: "Chamonix"
            ),
            willRequest: true
        )
        manager.restoreLastReading()

        // `willRequest: false` is what makes this an assertion about the
        // cache: without a cached reading this subject would draw as
        // unavailable rather than as a reading.
        manager.focus(on: budapestSubject, willRequest: false)

        #expect(manager.state == .reading(stored, subject: budapestSubject))
    }

    /// Once, and only once.
    ///
    /// A second call after the hiker has moved on must not drag last night's
    /// reading back over a current one.
    @Test("the restore happens once")
    func restoreHappensOnce() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let budapestSubject = WeatherSubject.place(budapest, name: "Budapest")
        store.save(snapshot: snapshot(celsius: 4), subject: budapestSubject)
        let manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        manager.restoreLastReading()
        #expect(manager.state == .reading(snapshot(celsius: 4), subject: budapestSubject))

        manager.focus(on: nil, willRequest: false)
        manager.restoreLastReading()

        #expect(manager.state == .idle)
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
