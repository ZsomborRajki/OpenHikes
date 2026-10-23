//
//  SyncedSettingsMirrorOrderingTests.swift
//  OpenHikesTests
//
//  Two notifications, two queues, and no promise about which runs first. A
//  change from another device lands in iCloud's store before its notification
//  reaches this one, and a local write lands in `UserDefaults` before its own.
//  In either window the mirror must not mistake an unchanged side for an
//  edited one, because whichever it believes, it writes over the other.
//
//  Every case drives the two handlers by hand, in the order under test, with a
//  private notification center so that nothing else delivers in between.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Synced settings mirror ordering")
struct SyncedSettingsMirrorOrderingTests {
    private enum Constants {
        static let osm = "openstreetmap"
        static let stadia = "stadia.outdoors"
        static let thunderforest = "thunderforest.outdoors"
    }

    private struct Harness {
        let defaults: UserDefaults
        let store: InMemoryCloudSettingsStore
        let mirror: SyncedSettingsMirror

        var localProvider: String? { defaults.string(forKey: SettingsKey.tileProviderID) }
        var remoteProvider: String? { store.object(forKey: SettingsKey.tileProviderID) as? String }
    }

    /// Both stores agreeing on `values`, and the mirror started over them.
    private static func harness(agreeingOn values: [String: Any]) throws -> Harness {
        let name = "SyncedSettingsMirrorOrderingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        for (key, value) in values { defaults.set(value, forKey: key) }
        let store = InMemoryCloudSettingsStore(values)
        let mirror = SyncedSettingsMirror(
            defaults: defaults,
            store: store,
            notificationCenter: NotificationCenter()
        )
        mirror.start()
        #expect(store.writes.isEmpty, "Agreeing stores should start without a write")
        return Harness(defaults: defaults, store: store, mirror: mirror)
    }

    private static func serverChange(_ keys: String...) -> SyncedSettingsCloudChange {
        SyncedSettingsCloudChange(reason: .server, keys: Set(keys))
    }

    /// The issue's own interleaving. Another device picks Stadia; before its
    /// notification arrives here, something unrelated is written to the same
    /// defaults. That write must not send this device's untouched choice back
    /// up over the new one.
    @Test("An unrelated local write does not push a stale value over an incoming change")
    func unrelatedWriteDoesNotEchoStaleValue() throws {
        let harness = try Self.harness(agreeingOn: [SettingsKey.tileProviderID: Constants.osm])

        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.defaults.set(UUID().uuidString, forKey: SettingsKey.lastSelectedHikeID)
        harness.mirror.defaultsDidChange()

        #expect(harness.store.writes.isEmpty)
        #expect(harness.remoteProvider == Constants.stadia)

        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.tileProviderID))

        #expect(harness.localProvider == Constants.stadia)
        #expect(harness.remoteProvider == Constants.stadia)
    }

    /// The reverse window. A switch flipped here has not been pushed yet when
    /// another device's change to a *different* key arrives; pulling that key
    /// must leave the flipped one alone, and the push that follows sends it.
    @Test("An incoming change to one key leaves a pending local edit to another")
    func incomingChangeLeavesOtherPendingEdit() throws {
        let harness = try Self.harness(agreeingOn: [
            SettingsKey.tileProviderID: Constants.osm,
            SettingsKey.showsHikingRoutes: false,
        ])

        harness.defaults.set(true, forKey: SettingsKey.showsHikingRoutes)
        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.tileProviderID))

        #expect(harness.localProvider == Constants.stadia)
        #expect(harness.defaults.bool(forKey: SettingsKey.showsHikingRoutes))

        harness.mirror.defaultsDidChange()

        #expect(harness.store.object(forKey: SettingsKey.showsHikingRoutes) as? Bool == true)
        #expect(harness.remoteProvider == Constants.stadia)
        #expect(harness.store.writes == [SettingsKey.showsHikingRoutes])
    }

    /// The same key edited on both devices, with the remote notification
    /// first. The local edit is the one the store has not yet been told about,
    /// so it is the later write to it, and the store's own last-writer-wins
    /// would keep it. The mirror keeps it too, and sends it.
    @Test("A pending local edit to the same key outlasts an incoming change")
    func pendingLocalEditWinsSameKey() throws {
        let harness = try Self.harness(agreeingOn: [SettingsKey.tileProviderID: Constants.osm])

        harness.defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)
        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.tileProviderID))

        #expect(harness.localProvider == Constants.thunderforest)
        #expect(harness.remoteProvider == Constants.thunderforest)

        // The local notification, arriving late, finds nothing left to send.
        harness.mirror.defaultsDidChange()
        #expect(harness.store.writes == [SettingsKey.tileProviderID])
    }

    /// The same two edits with the local notification first: pushed at once,
    /// and the late remote notification then pulls what the store holds.
    @Test("A local edit pushed first is not undone by the remote notification after it")
    func localEditPushedFirstStands() throws {
        let harness = try Self.harness(agreeingOn: [SettingsKey.tileProviderID: Constants.osm])

        harness.defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)
        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.mirror.defaultsDidChange()
        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.tileProviderID))

        #expect(harness.localProvider == Constants.thunderforest)
        #expect(harness.remoteProvider == Constants.thunderforest)
    }

    /// Once a local edit has been sent, a later change from elsewhere is the
    /// newer choice and is taken, and taking it sends nothing back.
    @Test("A remote change after the local edit was sent is adopted")
    func laterRemoteChangeIsAdopted() throws {
        let harness = try Self.harness(agreeingOn: [SettingsKey.tileProviderID: Constants.osm])

        harness.defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)
        harness.mirror.defaultsDidChange()
        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.tileProviderID))
        // The defaults notification for the mirror's own write.
        harness.mirror.defaultsDidChange()

        #expect(harness.localProvider == Constants.stadia)
        #expect(harness.remoteProvider == Constants.stadia)
        #expect(harness.store.writes == [SettingsKey.tileProviderID])
    }

    /// A notification names what moved; one that names only device-local keys
    /// brings nothing into this device's settings, even if iCloud somehow
    /// holds them.
    @Test("An incoming change to keys outside the allowlist moves nothing")
    func nonAllowlistedChangeIsIgnored() throws {
        let harness = try Self.harness(agreeingOn: [SettingsKey.tileProviderID: Constants.osm])
        let elsewhere = UUID().uuidString

        harness.store.receive(elsewhere, forKey: SettingsKey.lastSelectedHikeID)
        harness.mirror.cloudDidChange(Self.serverChange(SettingsKey.lastSelectedHikeID))

        #expect(harness.defaults.string(forKey: SettingsKey.lastSelectedHikeID) == nil)
    }

    /// A notification that does not say which keys moved is reconciled over
    /// the whole allowlist, by the same rule.
    @Test("An incoming change without a key list reconciles every synced key")
    func changeWithoutKeysReconcilesAll() throws {
        let harness = try Self.harness(agreeingOn: [
            SettingsKey.tileProviderID: Constants.osm,
            SettingsKey.savePhotosToLibrary: false,
        ])

        harness.store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        harness.store.receive(true, forKey: SettingsKey.savePhotosToLibrary)
        harness.mirror.cloudDidChange(SyncedSettingsCloudChange(reason: .server))

        #expect(harness.localProvider == Constants.stadia)
        #expect(harness.defaults.bool(forKey: SettingsKey.savePhotosToLibrary))
    }

    /// A new account, or the first download after joining one, is the
    /// restored-device case again: iCloud wins wherever it has a value, and
    /// this device's choices fill in only where it has none.
    @Test(
        "An account change or first download adopts iCloud first",
        arguments: [SyncedSettingsCloudChange.Reason.accountChange, .initialSync]
    )
    func accountChangeAdoptsRemoteFirst(reason: SyncedSettingsCloudChange.Reason) throws {
        let harness = try Self.harness(agreeingOn: [
            SettingsKey.tileProviderID: Constants.osm,
            SettingsKey.savePhotosToLibrary: true,
        ])

        harness.defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)
        harness.store.replaceAll(with: [SettingsKey.tileProviderID: Constants.stadia])
        harness.mirror.cloudDidChange(SyncedSettingsCloudChange(reason: reason))

        #expect(harness.localProvider == Constants.stadia)
        #expect(harness.remoteProvider == Constants.stadia)
        #expect(harness.store.object(forKey: SettingsKey.savePhotosToLibrary) as? Bool == true)

        // Adopting set the baseline, so the defaults notification for the
        // mirror's own write sends nothing back.
        let writes = harness.store.writes
        harness.mirror.defaultsDidChange()
        #expect(harness.store.writes == writes)
    }

    /// The observer is wired to the injected center and reads the keys from
    /// the notification, not from the store: iCloud also holds a change the
    /// notification does not name, and that one stays where it is.
    @Test("The store's notification reaches the mirror with its changed keys")
    func notificationIsWired() async throws {
        let center = NotificationCenter()
        let name = "SyncedSettingsMirrorOrderingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let agreed: [String: Any] = [
            SettingsKey.tileProviderID: Constants.osm,
            SettingsKey.savePhotosToLibrary: false,
        ]
        for (key, value) in agreed { defaults.set(value, forKey: key) }
        let store = InMemoryCloudSettingsStore(agreed)
        let mirror = SyncedSettingsMirror(defaults: defaults, store: store, notificationCenter: center)
        mirror.start()
        defer { mirror.stop() }

        store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        store.receive(true, forKey: SettingsKey.savePhotosToLibrary)
        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
                NSUbiquitousKeyValueStoreChangedKeysKey: [SettingsKey.tileProviderID],
            ]
        )

        await settleDelegateHop(until: "the incoming map style is pulled") {
            defaults.string(forKey: SettingsKey.tileProviderID) == Constants.stadia
        }
        #expect(defaults.string(forKey: SettingsKey.tileProviderID) == Constants.stadia)
        #expect(!defaults.bool(forKey: SettingsKey.savePhotosToLibrary))
    }
}
