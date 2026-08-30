//
//  CloudSyncCoordinatorTests.swift
//  OpenHikesTests
//
//  The two things left for this app to decide now that SwiftData does the
//  syncing: whether the user wants it, and whether the switch they just moved
//  has actually taken effect.
//
//  The second is the new one. A `ModelConfiguration` decides whether it
//  mirrors when it is built, so a switch flipped mid-session describes a store
//  that does not exist yet — and a settings row that answered "Synced with
//  iCloud" in that state would be telling a person their hikes were leaving a
//  device they had just told it not to leave.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Cloud sync coordinator")
struct CloudSyncCoordinatorTests {
    /// Its own defaults suite per test: these assert on persisted values, and
    /// suites run in parallel in one process against one `UserDefaults`.
    private static func defaults() throws -> UserDefaults {
        let name = "CloudSyncCoordinatorTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private static func coordinator(
        defaults: UserDefaults,
        isSyncingThisLaunch: Bool
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            defaults: defaults,
            isSyncingThisLaunch: isSyncingThisLaunch,
            storageIsDurable: true
        )
    }

    /// On by default, for the reason the property's own comment gives: a phone
    /// restored from backup showing an empty hikes list is the failure this
    /// feature exists to prevent.
    @Test("sync is on unless the user has said otherwise")
    func enabledByDefault() throws {
        let defaults = try Self.defaults()
        #expect(SettingsDefault.cloudSyncEnabled)
        #expect(CloudSyncCoordinator.isEnabled(in: defaults))
        #expect(Self.coordinator(defaults: defaults, isSyncingThisLaunch: true).isEnabled)
    }

    /// The switch has to outlive the process, because the process is what
    /// reads it: the container is built from this value on the next launch.
    @Test("turning sync off is remembered for the launch that acts on it")
    func disablingPersists() throws {
        let defaults = try Self.defaults()
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: true)

        coordinator.isEnabled = false

        #expect(defaults.bool(forKey: SettingsKey.cloudSyncEnabled) == false)
        #expect(!CloudSyncCoordinator.isEnabled(in: defaults))
        // What the next launch would build its container with.
        let relaunched = Self.coordinator(defaults: defaults, isSyncingThisLaunch: false)
        #expect(!relaunched.isEnabled)
        #expect(!relaunched.pendingRelaunch)
    }

    /// The gap the whole type exists to name: switch off, store still
    /// mirroring, until the app is next opened.
    @Test("a switch that this launch's store cannot honour asks for a relaunch")
    func flippingOffAsksForARelaunch() throws {
        let defaults = try Self.defaults()
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: true)
        #expect(!coordinator.pendingRelaunch)

        coordinator.isEnabled = false

        #expect(coordinator.pendingRelaunch)
        #expect(coordinator.status.pendingRelaunch)
        #expect(coordinator.status.title == "Restart to Apply")
    }

    /// And the same in the other direction, which is the more common one: a
    /// user who turned sync on expects their hikes to start travelling, and
    /// nothing will happen until the store is rebuilt.
    @Test("turning sync back on asks for the same relaunch")
    func flippingOnAsksForARelaunch() throws {
        let defaults = try Self.defaults()
        defaults.set(false, forKey: SettingsKey.cloudSyncEnabled)
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: false)
        #expect(!coordinator.pendingRelaunch)

        coordinator.isEnabled = true

        #expect(coordinator.pendingRelaunch)
        #expect(coordinator.status.detail.contains("reopen"))
    }

    /// Flipping back to where it started is not a pending change. Without
    /// this, a user who toggled the switch twice would be asked to restart for
    /// nothing.
    @Test("flipping the switch back clears the request")
    func flippingBackClearsTheRequest() throws {
        let defaults = try Self.defaults()
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: true)

        coordinator.isEnabled = false
        coordinator.isEnabled = true

        #expect(!coordinator.pendingRelaunch)
        #expect(!coordinator.status.pendingRelaunch)
    }

    /// A store that would not open runs on an in-memory fallback, which does
    /// not mirror whatever the switch says. Reporting it as syncing would be
    /// the one case where the row promises a backup that is not happening.
    @Test("a non-durable store never claims to be syncing")
    func fallbackStorageIsNeverSyncing() throws {
        let defaults = try Self.defaults()
        let coordinator = CloudSyncCoordinator(
            defaults: defaults,
            isSyncingThisLaunch: true,
            storageIsDurable: false
        )

        // The switch still reads on — the user did not turn it off — but this
        // launch is not honouring it, so it is a pending change and says so.
        #expect(coordinator.isEnabled)
        #expect(coordinator.pendingRelaunch)
    }

    /// Settings are the half of sync that does *not* wait for a relaunch:
    /// `NSUbiquitousKeyValueStore` is owned by this object outright rather
    /// than handed to it pre-configured, so the switch reaches it at once.
    ///
    /// What this can actually assert is the guard underneath that, and it is
    /// the one worth guarding: the key-value store is real iCloud even in a
    /// test host, so a coordinator built by the app that hosts these bundles
    /// must never start mirroring settings — in either switch position, and
    /// whether or not the store is durable.
    @Test(
        "the test host never mirrors settings to a real iCloud account",
        arguments: [true, false]
    )
    func settingsMirrorStaysOffUnderTests(enabled: Bool) throws {
        let defaults = try Self.defaults()
        defaults.set(enabled, forKey: SettingsKey.cloudSyncEnabled)
        let mirror = SyncedSettingsMirror(defaults: defaults)
        let coordinator = CloudSyncCoordinator(
            defaults: defaults,
            isSyncingThisLaunch: enabled,
            settings: mirror
        )

        coordinator.start()
        #expect(!mirror.isRunning)

        // And the switch cannot talk it into starting either.
        coordinator.isEnabled.toggle()
        #expect(!mirror.isRunning)
    }

    /// The reducer the mirroring observer feeds, on the branch that used to
    /// call `finished()`: an offline or rate-limited pass reported itself as a
    /// completed sync, so the row read "Synced with iCloud" with a time that
    /// nothing had earned.
    @Test("a transient mirroring failure does not advance the sync time")
    func transientOutcomeKeepsTheSyncTime() throws {
        let defaults = try Self.defaults()
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: true)
        coordinator.status.account = .available

        coordinator.apply(.began)
        coordinator.apply(.succeeded)
        let earned = try #require(coordinator.status.lastSyncedAt)

        coordinator.apply(.began)
        coordinator.apply(.transientFailure("The Internet connection appears to be offline."))
        coordinator.apply(.succeeded)

        #expect(coordinator.status.lastSyncedAt == earned)
        #expect(coordinator.status.activity == .retrying)
        #expect(coordinator.status.title != "Synced with iCloud")
    }

    /// And a device that has never managed a pass does not get a first sync
    /// time out of one that failed transiently.
    @Test("a transient mirroring failure never stamps a first sync time")
    func transientOutcomeStampsNoFirstSyncTime() throws {
        let defaults = try Self.defaults()
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: true)
        coordinator.status.account = .available

        coordinator.apply(.began)
        coordinator.apply(.transientFailure("Request rate limited."))
        coordinator.apply(.succeeded)

        #expect(coordinator.status.lastSyncedAt == nil)
    }

    /// A launch that deliberately does not mirror used to pause without ever
    /// resolving the account, and the account is what the row answers from —
    /// so the section read "Checking iCloud…" about a check nobody had
    /// started, for as long as the app stayed open.
    @Test("a launch with sync switched off says so instead of checking iCloud")
    func disabledLaunchSettlesTheRow() throws {
        let defaults = try Self.defaults()
        defaults.set(false, forKey: SettingsKey.cloudSyncEnabled)
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: false)

        coordinator.start()

        #expect(!coordinator.pendingRelaunch)
        #expect(coordinator.status.activity == .disabled)
        #expect(coordinator.status.title == "Sync Off")
        #expect(coordinator.status.detail == "Your hikes stay on this device only.")
    }

    /// Foregrounding re-runs the same path, and must not undo the answer it
    /// gave a moment ago.
    @Test("coming back to a switched-off launch keeps saying the same thing")
    func returningToADisabledLaunchSaysTheSameThing() throws {
        let defaults = try Self.defaults()
        defaults.set(false, forKey: SettingsKey.cloudSyncEnabled)
        let coordinator = Self.coordinator(defaults: defaults, isSyncingThisLaunch: false)
        coordinator.start()

        coordinator.sceneDidBecomeActive()

        #expect(coordinator.status.title == "Sync Off")
    }

    /// The regression that shipped: `CKContainer(identifier:)` is not the
    /// cheap construction it looks like — the first one in a process loads
    /// CloudKit and shakes hands with its daemon, synchronously — and a
    /// `Task {}` started from a method on this `@MainActor` type *inherits*
    /// that isolation. So the account check ran the handshake on the main
    /// thread, which on a fresh install pinned it for seconds: a new user's
    /// very first launch was a grey map, no sheet, and an app that did not
    /// respond to touch.
    ///
    /// Asserted through the seam rather than through a real container, because
    /// a test that builds one depends on a daemon and a connection. What broke
    /// was never CloudKit — it was which thread the work was handed to — and
    /// this test runs from the same main-actor context that caused it.
    @Test("work that must leave the main thread actually leaves it")
    func offMainThreadLeavesTheMainThread() async {
        // `pthread_main_np` rather than `Thread.isMainThread`, which Swift
        // makes unavailable from an `async` context — the very context the
        // question has to be asked in.
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")

        let ranOnMainThread = await CloudSyncCoordinator.offMainThread {
            pthread_main_np() != 0
        }

        #expect(!ranOnMainThread)
    }
}
