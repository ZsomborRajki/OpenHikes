//
//  WeatherAlertStateTests.swift
//  OpenHikesTests
//
//  The three-way alert state, and its survival across a relaunch.
//
//  Everything here turns on one distinction: WeatherKit returns `nil` where it
//  has no alerting partner and an *empty list* where it has one and has
//  nothing to say. Those are opposite facts, and drawing them the same way
//  would tell a hiker in a country nobody reports from that the ridge is
//  clear — on the authority of an app that has no idea.
//
//  So the mapping is asserted from the shape WeatherKit actually hands over,
//  including the `nil`, and the stored payload is asserted to carry the
//  difference rather than flatten it.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("What the alert state means")
struct WeatherAlertStateTests {
    private static let noon = Date(timeIntervalSince1970: 1_780_000_000)

    /// Non-optional on the type, so the fixture needs a real one — built
    /// through a static rather than force-unwrapped at each call site.
    private static func detailsURL(_ id: String) -> URL {
        URL(string: "https://weather.example/\(id)") ?? URL(filePath: "/")
    }

    private static func summary(
        id: String = "storm-1",
        severity: WeatherAlertSeverity = .severe
    ) -> WeatherAlertSummary {
        WeatherAlertSummary(
            id: id,
            summary: "Severe thunderstorm warning",
            severity: severity,
            detailsURL: detailsURL(id),
            source: "Deutscher Wetterdienst",
            expires: nil
        )
    }

    private static func snapshot(alerts: WeatherAlerts?) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.bolt.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Thunderstorms",
            capturedAt: noon,
            conditions: .preview,
            alerts: alerts
        )
    }

    // MARK: Nobody watching is not nothing to report

    /// The mapping asserted from the shape the framework hands over. `nil` is
    /// the input that matters and it is not defaulted away.
    @Test("no alerting partner reads as unavailable rather than clear")
    func absentAlertsAreUnavailable() {
        #expect(WeatherAlerts(nil) == .unavailable)
    }

    @Test("an empty list from a region that does report is the all-clear")
    func emptyAlertsAreClear() {
        #expect(WeatherAlerts([]) == .clear)
    }

    /// Said out loud because it is the assertion the feature is for: these two
    /// must never be the same value.
    @Test("the two empties are different states")
    func theTwoEmptiesAreDistinct() {
        #expect(WeatherAlerts(nil) != WeatherAlerts([]))
    }

    // MARK: Reading the worst one

    @Test("the most severe alert is the one picked out")
    func picksTheMostSevere() {
        let alerts = WeatherAlerts.active([
            Self.summary(id: "minor-1", severity: .minor),
            Self.summary(id: "extreme-1", severity: .extreme),
            Self.summary(id: "severe-1", severity: .severe),
        ])

        #expect(alerts.mostSevere?.id == "extreme-1")
    }

    @Test("neither empty has a most severe alert")
    func theEmptiesHaveNoWorstCase() {
        #expect(WeatherAlerts.clear.mostSevere == nil)
        #expect(WeatherAlerts.unavailable.mostSevere == nil)
        #expect(WeatherAlerts.clear.summaries.isEmpty)
        #expect(WeatherAlerts.unavailable.summaries.isEmpty)
    }

    /// An ungraded advisory is not evidence of danger, so it must not outrank
    /// a graded one. This is the ordering `WeatherAlertWatch`'s threshold
    /// rests on.
    @Test("an ungraded alert sorts below every graded one")
    func ungradedSortsLowest() {
        #expect(WeatherAlertSeverity.unknown < .minor)
        #expect(WeatherAlertSeverity.minor < .moderate)
        #expect(WeatherAlertSeverity.moderate < .severe)
        #expect(WeatherAlertSeverity.severe < .extreme)
    }

    // MARK: Surviving a relaunch

    /// The stored payload flattens the enum into two fields, and this is what
    /// says the flattening does not lose the distinction the whole feature
    /// turns on.
    @Test("the all-clear and nobody-watching survive the store apart")
    func theTwoEmptiesSurviveTheStoreApart() throws {
        let clearDefaults = try #require(UserDefaults(suiteName: "alerts-\(UUID().uuidString)"))
        let unwatchedDefaults = try #require(UserDefaults(suiteName: "alerts-\(UUID().uuidString)"))

        let clearStore = WeatherReadingStore(defaults: clearDefaults)
        clearStore.save(snapshot: Self.snapshot(alerts: .clear), subject: .uiTestFixtureSubject)
        let unwatchedStore = WeatherReadingStore(defaults: unwatchedDefaults)
        unwatchedStore.save(
            snapshot: Self.snapshot(alerts: .unavailable),
            subject: .uiTestFixtureSubject
        )

        #expect(try #require(clearStore.load()).snapshot.alerts == .clear)
        #expect(try #require(unwatchedStore.load()).snapshot.alerts == .unavailable)
    }

    @Test("a standing alert keeps its link and its source across a relaunch")
    func anActiveAlertSurvivesTheStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "alerts-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)
        let alerts = WeatherAlerts.active([Self.summary()])

        store.save(snapshot: Self.snapshot(alerts: alerts), subject: .uiTestFixtureSubject)
        let restored = try #require(store.load())

        #expect(restored.snapshot.alerts == alerts)
        // The link is the obligation, so it is asserted rather than assumed to
        // have come along with the rest.
        #expect(restored.snapshot.alerts?.mostSevere?.detailsURL.absoluteString
            == "https://weather.example/storm-1")
    }

    /// A reading written by a build that never asked for `.alerts` must not
    /// come back as "nobody is watching here" — that is a fact about this app
    /// rather than about the weather, and the sheet draws nothing for it.
    @Test("a reading that never carried alerts restores as absent, not unwatched")
    func anAbsentAlertStateIsNotUnavailable() throws {
        let defaults = try #require(UserDefaults(suiteName: "alerts-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)

        store.save(snapshot: Self.snapshot(alerts: nil), subject: .uiTestFixtureSubject)
        let restored = try #require(store.load())

        #expect(restored.snapshot.alerts == nil)
        // And the rest of the reading is untouched, which is the reason this
        // field is optional rather than decode-failing.
        #expect(restored.snapshot.conditionDescription == "Thunderstorms")
    }
}
