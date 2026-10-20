//
//  WalkDaylightCacheTests.swift
//  OpenHikesTests
//
//  A cached forecast stays where it was read even when its subject moves.
//  The badge follows the focus immediately; the walk must measure proximity
//  to the reading's source until a new forecast actually arrives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Walk daylight keeps the reading's location")
struct WalkDaylightCacheTests {
    private static let noon = Date(timeIntervalSince1970: 1_780_000_000)
    private static let walkedID = UUID()
    private static let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private static let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)
    private static let daylight = WeatherDaylight(civilDusk: noon.addingTimeInterval(8 * 3600))
    private static let snapshot = WeatherSnapshot(
        symbolName: "sun.max.fill",
        temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
        conditionDescription: "Clear",
        capturedAt: noon,
        conditions: .preview,
        daylight: daylight
    )

    @Test("moving focus does not move a cached or restored reading", arguments: [false, true], [false, true])
    func movingFocusKeepsTheReadingsLocation(isTrail: Bool, restored: Bool) throws {
        let subject: WeatherSubject = isTrail
            ? .trail(Self.vienna, hikeID: UUID(), name: "Elsewhere")
            : .me(Self.vienna)
        let manager: WeatherManager
        if restored {
            let defaults = try #require(UserDefaults(suiteName: "walk-daylight-\(UUID().uuidString)"))
            let store = WeatherReadingStore(defaults: defaults)
            store.save(snapshot: Self.snapshot, subject: subject)
            manager = WeatherManager(store: store, widgetPublisher: .inert)
            manager.restoreLastReading()
        } else {
            manager = WeatherManager(widgetPublisher: .inert)
            manager.applyUITestSnapshot(Self.snapshot, subject: subject)
        }

        // A pending request, or another focus while offline, keeps the old
        // forecast on the badge. Neither is a reading at the new coordinate.
        for willRequest in [true, false] {
            manager.focus(on: subject.moved(to: Self.budapest), willRequest: willRequest)
            #expect(manager.current == Self.snapshot)
            #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == nil)
            #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.vienna) == Self.daylight)
        }

        // Only an arriving reading supplies daylight at the new position.
        manager.applyUITestSnapshot(Self.snapshot, subject: subject.moved(to: Self.budapest))
        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == Self.daylight)
    }

    @Test("a deferred restore keeps the source of a reading that arrived first")
    func restoreKeepsAnArrivedReading() throws {
        let defaults = try #require(UserDefaults(suiteName: "walk-daylight-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)
        store.save(snapshot: Self.snapshot, subject: .me(Self.vienna))
        let manager = WeatherManager(store: store, widgetPublisher: .inert)
        manager.applyUITestSnapshot(Self.snapshot, subject: .me(Self.budapest))

        manager.restoreLastReading()

        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == Self.daylight)
        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.vienna) == nil)
        manager.focus(on: .me(Self.budapest), willRequest: false)
        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == Self.daylight)
    }
}
