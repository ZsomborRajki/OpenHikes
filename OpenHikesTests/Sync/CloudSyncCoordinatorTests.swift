//
//  CloudSyncCoordinatorTests.swift
//  OpenHikesTests
//
//  The three unrelated reasons sync might be doing nothing — the user turned
//  it off, there is no Apple Account, or this process is hosting a test bundle
//  — all meet in the coordinator. The first and the third are testable in
//  process; the second belongs to a device with an account on it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Cloud sync coordinator")
struct CloudSyncCoordinatorTests {
    /// Defaults of this case's own. These suites run in parallel and the real
    /// `UserDefaults` belongs to the host app.
    private struct Harness {
        let defaults: UserDefaults
        let suiteName: String
        let coordinator: CloudSyncCoordinator

        init() throws {
            suiteName = "CloudSyncCoordinatorTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            coordinator = CloudSyncCoordinator(
                container: try Fixture.modelContainer(),
                defaults: defaults
            )
        }

        func removeAll() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// On by default. This is the user's own private iCloud storage, and the
    /// failure the default prevents — a replaced phone opening to an empty
    /// list because a switch was never found — is the one people notice.
    @Test("Sync is on until the user says otherwise")
    func enabledByDefault() throws {
        let harness = try Harness()
        defer { harness.removeAll() }

        #expect(harness.coordinator.isEnabled)
        #expect(SettingsDefault.cloudSyncEnabled)
    }

    @Test("The switch is remembered across launches")
    func switchIsPersisted() throws {
        let harness = try Harness()
        defer { harness.removeAll() }

        harness.coordinator.isEnabled = false

        #expect(harness.defaults.bool(forKey: SettingsKey.cloudSyncEnabled) == false)
        let relaunched = CloudSyncCoordinator(
            container: try Fixture.modelContainer(),
            defaults: harness.defaults
        )
        #expect(!relaunched.isEnabled)
    }

    /// Both unit-test bundles are hosted by the app, so without this guard
    /// starting the app model would reach for a real iCloud account, a real
    /// container and the user's real hikes underneath suites that own their
    /// own store.
    @Test("A test host starts paused rather than reaching for iCloud")
    func testHostStaysPaused() throws {
        let harness = try Harness()
        defer { harness.removeAll() }

        #expect(AppLaunchEnvironment.isRunningTests)
        harness.coordinator.start()

        #expect(harness.coordinator.status.activity == .paused)
    }

    /// Every route into a state change has to be behind the test guard, not
    /// just `start()`. The coordinator built here points at the *host app's*
    /// real sync directory, so a toggle that reached the engine would delete
    /// the state and remembered records of whoever is running the tests —
    /// leaving their next real launch to re-download the zone and re-upload
    /// the whole library over it.
    @Test("Toggling the switch under a test host reaches no real storage")
    func togglingUnderTestsStaysPaused() async throws {
        let harness = try Harness()
        defer { harness.removeAll() }

        harness.coordinator.isEnabled = false
        harness.coordinator.isEnabled = true
        await Task.yield()

        #expect(harness.coordinator.status.activity == .paused)
    }

    /// A deletion is the one local change nothing can re-derive afterwards:
    /// the hike is gone, so no later scan of this device notices it is
    /// missing, while iCloud still holds a copy that the next fetch would
    /// bring back. It therefore has to be written down even with sync off.
    @Test("A hike deleted with sync off is still noticed")
    func deletionIsRecordedWithSyncOff() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(
            "CloudSyncCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CloudSyncStateStore(
            storageRoot: root.appendingPathComponent("support", isDirectory: true),
            stagingRoot: root.appendingPathComponent("caches", isDirectory: true)
        )
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext)
        try container.mainContext.save()
        let applier = HikeSyncApplier(container: container)
        let engine = HikeSyncEngine(
            applier: applier,
            status: CloudSyncStatus(),
            store: store
        )

        let identifiers = applier.deletionIdentifiers(of: hike)
        await engine.enqueueDeletions(
            hikeIDs: identifiers.hikeIDs,
            photoIDs: identifiers.photoIDs
        )

        // The engine was never started, which is also what a launch looks like
        // before the account round-trip comes back.
        #expect(await engine.isRunning == false)
        #expect(await store.pendingDeletionNames() == [hike.id.uuidString])
    }

    /// The settings row has to say something concrete in every state: "why
    /// isn't this working" is the only question that section exists to answer.
    @Test("Every account state has something to say")
    func statusAlwaysExplainsItself() {
        let status = CloudSyncStatus()
        let accounts: [CloudAccountStatus] = [.available, .noAccount, .restricted, .unknown]
        let activities: [CloudSyncActivity] = [.failed("Nope"), .idle, .paused, .working]

        for account in accounts {
            status.account = account
            for activity in activities {
                status.activity = activity
                #expect(!status.title.isEmpty)
                #expect(!status.detail.isEmpty)
            }
        }
    }

    @Test("Only an available account is usable")
    func onlyAvailableAccountIsUsable() {
        #expect(CloudAccountStatus.available.isUsable)
        #expect(!CloudAccountStatus.noAccount.isUsable)
        #expect(!CloudAccountStatus.restricted.isUsable)
        #expect(!CloudAccountStatus.unknown.isUsable)
    }
}
