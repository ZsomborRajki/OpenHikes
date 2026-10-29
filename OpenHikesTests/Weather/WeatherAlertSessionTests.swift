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
//  The permission prompt is the one place the gate is asked twice. The first
//  one stays up for as long as the hiker leaves it, so the held-prompt cases
//  change what is true behind it — the poll cancelled, the walk or the
//  recording over, the badge moved, the alert cleared or lapsed — and assert
//  that the answer posts nothing and spends nothing.
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

    // MARK: Permission

    /// A refused prompt posts nothing, so it must say nothing either: the
    /// hiker who then allows notifications in Settings and comes back to the
    /// same walk is still under the same warning.
    @Test("a refused permission leaves the alert to announce once it is granted")
    func refusedPermissionDoesNotSpendTheAlert() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)

        notifier.isAuthorized = false
        await manager.announceStandingAlerts(during: walk)
        #expect(notifier.posted.isEmpty)

        notifier.isAuthorized = true
        await manager.announceStandingAlerts(during: walk)
        await manager.announceStandingAlerts(during: walk)

        #expect(notifier.postedKinds == [.severeWeather])
    }

    /// The alert is recorded after `authorize()` returns, so a second pass
    /// can arrive while the first prompt is still up and find it unsaid. The
    /// second is answered at once and posts; the first, answered after it,
    /// must find nothing left. Held by the stub rather than raced, so the
    /// order is the test's and not the scheduler's.
    @Test("two attempts overlapping one prompt post one banner")
    func overlappingAttemptsPostOnce() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk) }
        guard await notifier.awaitPrompt() else { return }
        await manager.announceStandingAlerts(during: walk)
        #expect(notifier.postedKinds == [.severeWeather])

        notifier.answerPrompt(allowing: true)
        await first.value

        #expect(notifier.postedKinds == [.severeWeather])
        #expect(notifier.authorizationRequests == 2)
    }

    /// The other order: the held prompt is refused after a second pass was
    /// granted. The refusal must not undo what the granted pass said.
    @Test("a refusal answered after a granted overlap posts nothing more")
    func refusalAfterOverlapPostsNothingMore() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk) }
        guard await notifier.awaitPrompt() else { return }
        await manager.announceStandingAlerts(during: walk)
        notifier.answerPrompt(allowing: false)
        await first.value
        await manager.announceStandingAlerts(during: walk)

        #expect(notifier.postedKinds == [.severeWeather])
    }

    // MARK: An answer that outlives its question

    /// The prompt can stay up for as long as the hiker leaves it, and the poll
    /// that asked can be cancelled behind it. A cancelled attempt says nothing
    /// and spends nothing: the next pass still has the warning to give.
    @Test("a cancelled attempt posts nothing and leaves the alert unsaid")
    func cancelledAttemptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk) }
        guard await notifier.awaitPrompt() else { return }
        first.cancel()
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        await manager.announceStandingAlerts(during: walk)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    @Test("a walk that ends while the prompt is up is not interrupted")
    func walkEndingDuringThePromptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let moment = Moment(session: .walking(hikeID: Self.walkedID))
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: moment.session) }
        guard await notifier.awaitPrompt() else { return }
        moment.session = .browsing
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        moment.session = .walking(hikeID: Self.walkedID)
        await manager.announceStandingAlerts(during: moment.session)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    @Test("a recording that stops while the prompt is up is not interrupted")
    func recordingEndingDuringThePromptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: .me(Self.ridge))
        let moment = Moment(session: .recording)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: moment.session) }
        guard await notifier.awaitPrompt() else { return }
        moment.session = .browsing
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        moment.session = .recording
        await manager.announceStandingAlerts(during: moment.session)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    /// Another trail opened mid-walk is browsing again, so the answer finds
    /// nothing of the hiker's on the badge — not even the storm standing over
    /// the trail opened. The walked trail's warning is still unsaid when the
    /// badge comes back to it.
    @Test("a badge moved off the walked trail while the prompt is up posts nothing")
    func subjectSwitchDuringThePromptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk) }
        guard await notifier.awaitPrompt() else { return }
        manager.applyUITestSnapshot(Self.snapshot(), subject: Self.otherTrail)
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        manager.focus(on: Self.walkedTrail, willRequest: false)
        await manager.announceStandingAlerts(during: walk)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    /// The fetch that lands while the prompt is up is the reading the answer
    /// is weighed against, so a storm that cleared is not announced from the
    /// reading that still had it — nor marked said, so the same warning
    /// issued again is still news.
    @Test("a clear reading that replaces the alert while the prompt is up posts nothing")
    func clearReadingDuringThePromptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk) }
        guard await notifier.awaitPrompt() else { return }
        manager.applyUITestSnapshot(Self.snapshot(alerts: .clear), subject: Self.walkedTrail)
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        manager.applyUITestSnapshot(Self.snapshot(), subject: Self.walkedTrail)
        await manager.announceStandingAlerts(during: walk)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    @Test("a reading that goes stale while the prompt is up posts nothing")
    func readingGoingStaleDuringThePromptPostsNothing() async throws {
        let (manager, notifier) = try Self.manager(showing: Self.walkedTrail)
        let walk = WeatherAlertSession.walking(hikeID: Self.walkedID)
        let moment = Moment(session: walk)
        let start = moment.now
        notifier.holdsThePrompt = true

        let first = Task { await manager.announceStandingAlerts(during: walk, asOf: moment.now) }
        guard await notifier.awaitPrompt() else { return }
        moment.now = start.addingTimeInterval(WeatherPollingPolicy.standard.stalenessInterval)
        notifier.answerPrompt(allowing: true)
        await first.value
        #expect(notifier.posted.isEmpty)

        await manager.announceStandingAlerts(during: walk, asOf: start)
        #expect(notifier.postedKinds == [.severeWeather])
    }

    // MARK: Fixtures

    /// What is true when the prompt is answered, changed by the test while it
    /// is up. A class, because the announcement reads it back after the
    /// suspension rather than taking a copy before it.
    @MainActor
    private final class Moment {
        var session: WeatherAlertSession
        var now = Date.now

        init(session: WeatherAlertSession) {
            self.session = session
        }
    }

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

    private static func snapshot(alerts: WeatherAlerts = storm) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.bolt.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Thunderstorms",
            capturedAt: .now,
            conditions: .preview,
            alerts: alerts
        )
    }

    private static let storm = WeatherAlerts.active([
        WeatherAlertSummary(
            id: "storm-1",
            summary: "Severe thunderstorm warning",
            severity: .severe,
            detailsURL: URL(string: "https://weather.example/storm-1") ?? URL(filePath: "/"),
            source: "Deutscher Wetterdienst"
        ),
    ])
}
