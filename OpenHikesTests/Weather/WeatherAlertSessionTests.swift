//
//  WeatherAlertSessionTests.swift
//  OpenHikesTests
//
//  The severe-weather banner waits for a walk or a recording.
//
//  Browsing trails moves the badge from ridge to ridge, and each reading that
//  lands carries whatever alerts stand there. Before this gate every one of
//  them could post a banner, for weather nobody was out in. The rule is
//  ``WeatherAlertSession/covers(_:)``, asserted directly; the manager half
//  asserts that a covered subject still interrupts, that an uncovered one does
//  not, and — the reason the gate is ahead of the watch rather than behind it —
//  that an alert read while browsing is still news when the walk starts.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Severe-weather banners wait for a walk or a recording")
struct WeatherAlertSessionTests {
    private static let ridge = CLLocationCoordinate2D(latitude: 47.55, longitude: 18.9)
    private static let walkedID = UUID()
    private static let otherID = UUID()

    private static let walkedTrail = WeatherSubject.trail(ridge, hikeID: walkedID, name: "Ridge")
    private static let otherTrail = WeatherSubject.trail(ridge, hikeID: otherID, name: "Valley")
    private static let searched = WeatherSubject.place(ridge, name: "Budapest")

    // MARK: Whose weather it is

    @Test("browsing covers nothing, not even the hiker")
    func browsingCoversNothing() {
        let session = WeatherAlertSession.browsing
        #expect(!session.covers(.me(Self.ridge)))
        #expect(!session.covers(Self.walkedTrail))
        #expect(!session.covers(Self.searched))
    }

    @Test("a walk covers its own trail and the hiker, and nothing opened beside it")
    func walkCoversItsTrail() {
        let session = WeatherAlertSession.walking(hikeID: Self.walkedID)
        #expect(session.covers(Self.walkedTrail))
        #expect(session.covers(.me(Self.ridge)))
        #expect(!session.covers(Self.otherTrail))
        #expect(!session.covers(Self.searched))
    }

    /// The pin moves the subject to `me` when a recording starts, so a trail
    /// under a recording is a reading for whatever was showing just before.
    @Test("a recording covers only the hiker")
    func recordingCoversTheHiker() {
        let session = WeatherAlertSession.recording
        #expect(session.covers(.me(Self.ridge)))
        #expect(!session.covers(Self.walkedTrail))
        #expect(!session.covers(Self.searched))
    }

    // MARK: The manager

    @Test("a reading for the walked trail interrupts")
    func walkedTrailInterrupts() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)

        await manager.announceStandingAlerts(during: .walking(hikeID: Self.walkedID))

        #expect(notifier.postedKinds == [.severeWeather])
    }

    @Test("a reading for a browsed trail does not")
    func browsedTrailIsQuiet() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)

        await manager.announceStandingAlerts(during: .browsing)
        await manager.announceStandingAlerts(during: .walking(hikeID: Self.otherID))

        #expect(notifier.posted.isEmpty)
        #expect(notifier.authorizationRequests == 0)
    }

    /// The reason the gate sits before the watch: had browsing marked the
    /// alert as said, starting the walk would have stayed silent.
    @Test("an alert read while browsing is announced when the walk starts")
    func browsingDoesNotSpendTheAlert() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)

        await manager.announceStandingAlerts(during: .browsing)
        await manager.announceStandingAlerts(during: .walking(hikeID: Self.walkedID))
        await manager.announceStandingAlerts(during: .walking(hikeID: Self.walkedID))

        #expect(notifier.postedKinds == [.severeWeather])
    }

    @Test("a stale reading does not interrupt even on the walked trail")
    func staleReadingIsQuiet() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let later = Date.now.addingTimeInterval(WeatherPollingPolicy.standard.stalenessInterval)

        await manager.announceStandingAlerts(during: .walking(hikeID: Self.walkedID), asOf: later)

        #expect(notifier.posted.isEmpty)
    }

    // MARK: Fixtures

    /// A manager with a fresh reading carrying one severe alert on the badge,
    /// put there the way a launch puts one: through the store's restore.
    private static func manager(
        showing subject: WeatherSubject
    ) throws -> (WeatherManager, StubMovementReminderNotifier) {
        let defaults = try #require(UserDefaults(suiteName: "weather-alert-session-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)
        store.save(snapshot: snapshot(), subject: subject)
        let notifier = StubMovementReminderNotifier()
        let manager = WeatherManager(store: store, notifier: notifier, widgetPublisher: .inert)
        manager.restoreLastReading()
        return (manager, notifier)
    }

    private static func snapshot() -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.bolt.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Thunderstorms",
            capturedAt: .now,
            conditions: .preview,
            alerts: .active([
                WeatherAlertSummary(
                    id: "storm-1",
                    summary: "Severe thunderstorm warning",
                    severity: .severe,
                    detailsURL: URL(string: "https://weather.example/storm-1") ?? URL(filePath: "/"),
                    source: "Deutscher Wetterdienst",
                    expires: nil
                ),
            ])
        )
    }
}
