//
//  BackgroundTrackingOutcomeTests.swift
//  OpenHikesTests
//
//  What the background-tracking switch is able to report about itself.
//
//  Its own suite rather than a few more cases in
//  `BackgroundTrackingAuthorizationTests`, because that one asks a different
//  question: which CoreLocation calls the tracker makes, and when. This asks
//  what the *switch* can say afterwards — and the answer used to be nothing at
//  all. `setEnabled(true)` with Always access refused asked nothing, started
//  nothing and returned nothing, so Settings wrote `true` to `@AppStorage` and
//  showed an enabled feature that could never run, across every launch after.
//  Reported by the user 2026-09-20.
//
//  The stub monitor, the scratch defaults and the fixture container are the
//  neighbouring suite's; see `BackgroundTrackingTests.swift` for what each one
//  stands in for.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Background tracking outcome")
final class BackgroundTrackingOutcomeTests {
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive while the monitor holds its
    // delegate weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        defaults = try makeScratchDefaults()
    }

    private func makeTracker() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    // MARK: The refusal the switch has to report

    /// The whole point of the return value. Nothing here can ask again —
    /// `requestAlwaysAuthorization` on a denied install shows nothing — so the
    /// switch has to stop claiming the feature and send the hiker to Settings.
    @Test("a refused install says so")
    func deniedNeedsSettings() {
        monitor.authorization = .denied
        let tracker = makeTracker()

        #expect(tracker.setEnabled(true) == .needsSettings)
    }

    /// And asks for nothing on the way, which is what makes the alert the only
    /// thing the hiker sees: a request that shows no prompt is a request that
    /// looks, from the outside, exactly like the app doing nothing.
    @Test("a refused install is not asked again")
    func deniedDoesNotRequest() {
        monitor.authorization = .denied
        let tracker = makeTracker()

        tracker.setEnabled(true)

        #expect(monitor.alwaysAccessRequests == 0)
    }

    // MARK: The cases that are not a refusal

    /// A prompt is going up, and the switch must stay on underneath it. Turning
    /// itself off here would be the app answering the system's alert for the
    /// hiker before they have.
    @Test("an unanswered install waits for the prompt")
    func notDeterminedAwaitsPrompt() {
        monitor.authorization = .notDetermined
        let tracker = makeTracker()

        #expect(tracker.setEnabled(true) == .awaitingPrompt)
        #expect(monitor.alwaysAccessRequests == 1)
    }

    /// When In Use granted and Always not yet asked for is the same shape: the
    /// upgrade prompt is what goes up, and it is still the hiker's to answer.
    @Test("a When In Use install waits for the upgrade prompt")
    func whenInUseAwaitsPrompt() {
        monitor.authorization = .whenInUse
        let tracker = makeTracker()

        #expect(tracker.setEnabled(true) == .awaitingPrompt)
        #expect(monitor.alwaysAccessRequests == 1)
    }

    @Test("an install that already granted Always is settled")
    func alwaysIsSettled() {
        monitor.authorization = .always
        let tracker = makeTracker()

        #expect(tracker.setEnabled(true) == .settled)
    }

    /// Turning the feature *off* always settles, whatever the grant is. There
    /// is nothing to ask about and nothing that can refuse.
    @Test("turning it off settles even with no grant at all")
    func disablingAlwaysSettles() {
        monitor.authorization = .denied
        let tracker = makeTracker()

        #expect(tracker.setEnabled(false) == .settled)
    }
}
