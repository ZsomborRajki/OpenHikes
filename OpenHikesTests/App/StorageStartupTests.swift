//
//  StorageStartupTests.swift
//  OpenHikesTests
//
//  The store-open failure path: what the app does when SwiftData will not open
//  the store the user's hikes live in.
//
//  Worth a suite of its own because of the policy around it. The store is
//  deliberately not migrated across schema changes — a store written by an
//  older shape of `Hike` is not a supported input, and the documented answer is
//  that the user reinstalls. That is only tolerable because the *failing*
//  launch is survivable: the app has to come up, say so, and leave what is on
//  disk alone. A crash here turns "your saved hikes are unavailable this
//  launch" into "the app is broken", and a silent fallback is worse still — a
//  user editing an in-memory store all day and losing it at the next launch.
//
//  These suites drive real SwiftData failures — a store file that is not a
//  store — rather than a synthetic `Error`, because the questions worth asking
//  are what SwiftData actually raises and what survives it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

/// A directory holding a `Hikes`/`HikeLocalState` pair, either of which can be
/// corrupted before the container is opened.
///
/// A class rather than a value type so `deinit` does the cleanup: Swift Testing
/// gives a suite instance per test, so the sandbox's lifetime is already
/// exactly the test's. Same arrangement, and same reason, as ``TileSandbox``.
nonisolated private final class StoreSandbox: Sendable {
    let root: URL
    let hikesURL: URL
    let localURL: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-sandbox-\(UUID().uuidString)", isDirectory: true)
        hikesURL = root.appendingPathComponent("Hikes.store")
        localURL = root.appendingPathComponent("HikeLocalState.store")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Makes `url` something SwiftData cannot open, the way a truncated write
    /// or a store from a schema this build no longer knows would: the file is
    /// there, and it is not a store.
    func corrupt(_ url: URL) throws {
        try Data("this is not a SQLite database".utf8).write(to: url)
    }

    func openContainer() throws -> ModelContainer {
        try ModelContainer.openHikes(url: hikesURL, localURL: localURL)
    }

    func inMemoryFallback() throws -> ModelContainer {
        try ModelContainer.openHikes(isStoredInMemoryOnly: true)
    }
}

@Suite("Store open failure")
struct StoreOpenFailureTests {
    private static let claimedTileKey = "osm/14/8723/5685@2.0"

    /// The premise everything below rests on: an unreadable store makes
    /// SwiftData throw rather than open something empty. If this stopped being
    /// true the app would come up with a blank hike list and no alert, which is
    /// the one outcome worse than the alert.
    @Test("an unreadable store file makes the container throw rather than open empty")
    func corruptStoreThrows() throws {
        let sandbox = StoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        #expect(throws: (any Error).self) {
            try sandbox.openContainer()
        }
    }

    /// The whole branch in one test: a real store that will not open produces a
    /// real ``StorageStartupIssue``, and the launch continues on the fallback
    /// rather than ending in a crash.
    @Test("an unreadable store falls back to temporary storage and reports it")
    func corruptStoreFallsBackAndReports() throws {
        let sandbox = StoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )

        let issue = try #require(load.startupIssue, "a failed open the user is never told about is the bug")
        #expect(!issue.underlyingDescription.isEmpty)
    }

    /// And the fallback is a container the app can actually run on. One that
    /// opens but cannot hold a `Hike`, or carries only the mirrored half of the
    /// pair, would turn the failed launch into a crash one screen later.
    @Test("the fallback container still holds both stores")
    func fallbackContainerIsUsable() throws {
        let sandbox = StoreSandbox()
        try sandbox.corrupt(sandbox.hikesURL)

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        let context = ModelContext(load.container)
        let hike = Fixture.hike(in: context, title: "Written to the fallback")
        // The sidecar too: they come as a pair, and a container with only the
        // mirrored half fails at the first tile a hike tries to claim.
        hike.autoSavedTileKeys = [Self.claimedTileKey]

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.autoSavedTileKeys == [Self.claimedTileKey])
    }

    /// A store the app has written and can read again — the common case, and
    /// the one a suite of corrupt-file tests could quietly stop covering. If
    /// the URL pair were wrong, every test above would "pass" against a store
    /// that had never opened successfully in the first place.
    @Test("a store written once reopens with its hike intact")
    func writtenStoreReopens() throws {
        let sandbox = StoreSandbox()
        let written = ModelContext(try sandbox.openContainer())
        let identifier = Fixture.hike(in: written, title: "Survives a reopen").id
        try written.save()

        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        let reopened = ModelContext(load.container)

        #expect(load.startupIssue == nil)
        #expect(try reopened.fetch(FetchDescriptor<Hike>()).first?.id == identifier)
    }
}

/// Which of the two stores failed — and the finding that the app cannot tell.
///
/// `Hike` lives in a mirrored store and `HikeLocalState` in an unmirrored one,
/// and losing them does not cost the same thing: the sidecar holds tile and
/// photo bookkeeping this device can rebuild, while the mirrored store holds
/// the user's hikes. They are nonetheless two configurations of *one*
/// `ModelContainer`, so either failing fails the open, and both arrive at
/// ``StorageStartupIssue`` as the same string.
///
/// This suite pins that rather than papering over it. The assertions are
/// written as claims about today's behaviour, so the day someone attributes a
/// failure to a store, they fail and say what changed.
@Suite("Store failure attribution")
struct StoreFailureAttributionTests {
    private func issue(corrupting store: KeyPath<StoreSandbox, URL>) throws -> StorageStartupIssue {
        let sandbox = StoreSandbox()
        try sandbox.corrupt(sandbox[keyPath: store])
        let load = try OpenHikesModel.loadContainer(
            persistent: { try sandbox.openContainer() },
            fallback: { try sandbox.inMemoryFallback() }
        )
        return try #require(load.startupIssue)
    }

    /// The device-local store failing is not survivable on its own terms: it
    /// takes the mirrored store down with it, and the launch runs on temporary
    /// storage as though the hikes themselves were unreadable.
    @Test("a corrupt device-local store fails the launch as hard as a corrupt hike store")
    func localStoreFailureIsAlsoAStartupIssue() throws {
        _ = try issue(corrupting: \.localURL)
    }

    /// The finding. ``StorageStartupIssue`` carries only its
    /// `underlyingDescription`, and SwiftData reports both as the same
    /// `loadIssueModelContainer` with no explanation attached — so nothing
    /// downstream, `OpenHikesView`'s "Saved Hikes Unavailable" alert included,
    /// can say which store went.
    ///
    /// Left as it is on purpose: attributing it means opening each
    /// configuration separately to find out which one throws, which is a second
    /// store-open on the launch path to produce a message the user cannot act
    /// on either way — the answer to both is the same reinstall. Recorded here
    /// so it stays a known cost rather than becoming a surprise.
    @Test("the two failures are reported identically, so the alert cannot name a cause")
    func failuresAreIndistinguishable() throws {
        let mirrored = try issue(corrupting: \.hikesURL)
        let deviceLocal = try issue(corrupting: \.localURL)

        #expect(
            mirrored == deviceLocal,
            """
            These have started reporting differently. If the description now names a store, \
            StorageStartupIssue can carry which one failed, and the alert can stop telling a \
            user their hikes are unavailable when only the sidecar is.
            """
        )
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
