//
//  WalkDaylightCacheTests.swift
//  OpenHikesTests
//
//  A walk's dusk comes from the cached readings, not from the badge. A
//  cached forecast stays where it was read even when its subject moves: the
//  badge follows the focus immediately, and the walk must measure proximity
//  to the reading's source until a new forecast actually arrives. And the
//  badge moving to a distant trail leaves the walked trail's reading in the
//  cache, still the walk's.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Walk daylight from cached readings")
struct WalkDaylightCacheTests {
    private static let noon = Date(timeIntervalSince1970: 1_780_000_000)
    private static let walkedID = UUID()
    private static let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private static let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)
    private static let daylight = WeatherDaylight(civilDusk: noon.addingTimeInterval(8 * 3600))
    private static let snapshot = reading(capturedAt: noon, daylight: daylight)

    private static func reading(capturedAt: Date, daylight: WeatherDaylight) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: capturedAt,
            conditions: .preview,
            daylight: daylight
        )
    }

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

    /// The badge follows browsing; the walk does not. A trail opened in
    /// another country takes the badge, and the walked trail's reading is
    /// still the walk's.
    @Test("the walked trail's cached reading counts while the badge shows a distant trail")
    func theWalkedTrailCountsWhileBrowsing() {
        let manager = WeatherManager(widgetPublisher: .inert)
        let walked = WeatherSubject.trail(Self.budapest, hikeID: Self.walkedID, name: "Ridge Loop")
        let browsed = WeatherSubject.trail(Self.vienna, hikeID: UUID(), name: "Wienerwald")
        let browsedLight = WeatherDaylight(civilDusk: Self.noon.addingTimeInterval(9 * 3600))
        manager.applyUITestSnapshot(Self.snapshot, subject: walked)
        manager.applyUITestSnapshot(Self.reading(capturedAt: Self.noon, daylight: browsedLight), subject: browsed)

        #expect(manager.state.subject == browsed)
        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == Self.daylight)
    }

    /// The cache is ordered by use, not by age: going back to a trail last
    /// read yesterday puts yesterday's reading — and its dusk — on the badge
    /// until the fetch lands, and the hiker's reading from this morning is
    /// the better answer meanwhile.
    @Test("the newest reading about the walk wins over the most recently used")
    func theNewestReadingWins() {
        let manager = WeatherManager(widgetPublisher: .inert)
        let walked = WeatherSubject.trail(Self.budapest, hikeID: Self.walkedID, name: "Ridge Loop")
        let yesterday = Self.noon.addingTimeInterval(-24 * 3600)
        let yesterdaysLight = WeatherDaylight(civilDusk: yesterday.addingTimeInterval(8 * 3600))
        manager.applyUITestSnapshot(Self.reading(capturedAt: yesterday, daylight: yesterdaysLight), subject: walked)
        manager.applyUITestSnapshot(Self.snapshot, subject: .me(Self.budapest))
        manager.focus(on: walked, willRequest: true)

        #expect(manager.state.subject == walked)
        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == Self.daylight)
    }

    @Test("with nothing cached there is no daylight")
    func nothingCachedNoDaylight() {
        let manager = WeatherManager(widgetPublisher: .inert)
        manager.focus(on: .trail(Self.budapest, hikeID: Self.walkedID, name: "Ridge Loop"), willRequest: true)

        #expect(manager.daylight(forWalkOn: Self.walkedID, at: Self.budapest) == nil)
    }
}
