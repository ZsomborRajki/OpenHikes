//
//  StorageStartupAlertTests.swift
//  OpenHikesTests
//
//  "Storage startup alert", split out of StorageStartupTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

/// A real ``OpenHikesModel`` carrying a chosen ``StorageStartupIssue``, with
/// every dependency that would otherwise reach a singleton handed in.
///
/// A class so it owns the tile sandbox for as long as the model does: the
/// controller holds the store, the store holds the cache, and the cache's
/// directories go when this does.
///
/// Assembling one is the point rather than an inconvenience. Nothing else in
/// the bundle builds an `OpenHikesModel`, which is exactly why the issue it
/// carries out of a failed launch had never been exercised.
@MainActor
private final class StartupModelProbe {
    let model: OpenHikesModel
    // periphery:ignore - assigned and never read on purpose; TileSandbox deletes
    // its directory on deinit, and the model above is still using it.
    private let sandbox: TileSandbox

    init(startupIssue: StorageStartupIssue?) throws {
        let container = try Fixture.modelContainer()
        let tiles = TileSandbox()
        sandbox = tiles
        // Two suites rather than one, because the tracker and the model both
        // write settings and neither should read the other's.
        let trackerDefaults = try Self.isolatedDefaults()
        let modelDefaults = try Self.isolatedDefaults()
        model = OpenHikesModel(
            container: container,
            backgroundTracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                defaults: trackerDefaults
            ),
            // No drain interval: this model exists to answer a question about
            // one property, and a timer draining an empty store until the test
            // ends is work nothing here observes.
            autoSaveController: AutoSaveController(store: tiles.store, drainInterval: nil),
            hikeRecorder: HikeRecorder(container: container),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            // Dormant, like the rest of this model's location stack: nothing
            // here asks about the weather, and a live feed would arm
            // significant-change monitoring under a suite about storage.
            significantLocations: SignificantLocationFeed(monitor: DormantLocationSource()),
            defaults: modelDefaults,
            startupIssue: startupIssue
        )
    }

    /// A suite of its own, wiped on the way in.
    ///
    /// `#require` rather than a fallback: both unit bundles are hosted by the
    /// app, so `.standard` here is the developer's own settings, and a helper
    /// that quietly hands them back on a nil suite is worse than one that
    /// fails. Nothing on this path can reach them.
    private static func isolatedDefaults() throws -> UserDefaults {
        let name = "com.openhikes.tests.startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// ``StorageStartupIssue`` as the alert in `OpenHikesView` uses it.
///
/// That alert is driven by `showingStorageStartupIssue`, a `Binding<Bool>`
/// whose getter is `appModel.startupIssue != nil` and whose setter clears the
/// issue on dismissal. Two ways that goes wrong, neither of them loud: a
/// binding that never reads `true` shows nothing at all, and one that never
/// returns to `false` re-presents the alert forever. Both are properties of
/// ``OpenHikesModel/startupIssue`` rather than of the view, which is what makes
/// them assertable from here.
@Suite("Storage startup alert")
struct StorageStartupAlertTests {
    /// The binding under test, spelled the way `OpenHikesView` spells it.
    private func presentationBinding(for model: OpenHikesModel) -> Binding<Bool> {
        Binding(
            get: { model.startupIssue != nil },
            set: { if !$0 { model.startupIssue = nil } }
        )
    }

    @Test("an issue raises the alert, and dismissing it puts the alert away for good")
    func bindingTurnsOnAndOffAgain() throws {
        let probe = try StartupModelProbe(startupIssue: StorageStartupIssue(underlyingDescription: "corrupt"))
        let binding = presentationBinding(for: probe.model)

        #expect(binding.wrappedValue, "a launch that failed has to present something")

        binding.wrappedValue = false

        #expect(probe.model.startupIssue == nil, "dismissal has to clear the state the getter reads")
        #expect(!binding.wrappedValue, "an alert that re-presents itself cannot be dismissed at all")
    }

    @Test("a healthy launch presents nothing")
    func bindingStaysDownOnAHealthyLaunch() throws {
        let probe = try StartupModelProbe(startupIssue: nil)

        #expect(!presentationBinding(for: probe.model).wrappedValue)
    }

    /// The getter is a plain property read, so the alert only ever appears if
    /// writing the property invalidates the body that reads it.
    /// `@ObservationIgnored` on `startupIssue` would leave every assertion
    /// above passing and the alert permanently invisible.
    @Test("setting the issue notifies observers, which is what draws the alert")
    func startupIssueIsObserved() async throws {
        let probe = try StartupModelProbe(startupIssue: nil)
        let observed = ObservationCounter { _ = probe.model.startupIssue }

        probe.model.startupIssue = StorageStartupIssue(underlyingDescription: "corrupt")

        // The notification is synchronous but the counter's re-registration
        // hops, so wait on the effect by name rather than on a yield count.
        await settleDelegateHop(until: "the observation of startupIssue to have fired") {
            observed.count > 0
        }
        #expect(observed.count > 0)
    }

    /// `.alert(isPresented:)` re-presents on a *transition* of its `Bool`, and
    /// the transition is computed from equality of what produced it. Two
    /// launches failing the same way have to compare equal, or a re-assignment
    /// that changed nothing would flicker the alert.
    @Test("issues compare by their cause")
    func equalityFollowsTheCause() {
        let cause = "The operation couldn't be completed."
        let reported = StorageStartupIssue(underlyingDescription: cause)
        let reportedAgain = StorageStartupIssue(underlyingDescription: cause)
        let different = StorageStartupIssue(underlyingDescription: "a different failure entirely")

        #expect(reported == reportedAgain)
        #expect(reported != different)
    }
}
