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

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "weather-store-\(UUID().uuidString)"))
    }

    private func snapshot(celsius: Double) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt
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

    /// A reading about the walker comes back as one, not as a place with no
    /// name — the badge draws its "here" form off exactly this.
    @Test("a reading about the walker restores without a place name")
    func restoresTheWalkerWithoutAName() throws {
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
}
