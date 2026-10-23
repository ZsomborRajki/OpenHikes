//
//  SyncedSettingsMirrorDeliveryTests.swift
//  OpenHikesTests
//
//  The mirror as the system delivers to it. `UserDefaults` posts its change
//  notification on the default center from inside `set`, and an observer on
//  `.main` runs before a main-thread `set` returns, so each value the mirror
//  pulls reaches its own defaults observer in the middle of the pull. The
//  ordering suite drives the handlers by hand on a private center and cannot
//  see that window; these cases start the mirror on the default center, where
//  only this suite's own defaults and store can reach it.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Synced settings mirror delivery")
struct SyncedSettingsMirrorDeliveryTests {
    private enum Constants {
        static let osm = "openstreetmap"
        static let stadia = "stadia.outdoors"
        static let thunderforest = "thunderforest.outdoors"
    }

    /// This device's values, which iCloud's must replace.
    private static let local: [String: Any] = [
        SettingsKey.tileProviderID: Constants.osm,
        SettingsKey.showsHikingRoutes: false,
        SettingsKey.savePhotosToLibrary: false,
    ]

    /// The person's choices, made on another device.
    private static let remote: [String: Any] = [
        SettingsKey.tileProviderID: Constants.stadia,
        SettingsKey.showsHikingRoutes: true,
        SettingsKey.savePhotosToLibrary: true,
    ]

    private static func defaults(holding values: [String: Any]) throws -> UserDefaults {
        let name = "SyncedSettingsMirrorDeliveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    private static func expectRemoteAdopted(in defaults: UserDefaults) {
        #expect(defaults.string(forKey: SettingsKey.tileProviderID) == Constants.stadia)
        #expect(defaults.bool(forKey: SettingsKey.showsHikingRoutes))
        #expect(defaults.bool(forKey: SettingsKey.savePhotosToLibrary))
    }

    /// The restored device. Adopting iCloud's values writes three keys into
    /// `defaults`, and the notification each write posts arrives while the
    /// others are still this device's old values; none of those may go up.
    @Test("Starting over a store that disagrees takes iCloud's values and sends nothing")
    func startSendsNothingStale() throws {
        let defaults = try Self.defaults(holding: Self.local)
        let store = InMemoryCloudSettingsStore(Self.remote)
        let mirror = SyncedSettingsMirror(defaults: defaults, store: store, notificationCenter: .default)

        mirror.start()
        defer { mirror.stop() }

        #expect(store.writes.isEmpty)
        Self.expectRemoteAdopted(in: defaults)
    }

    /// Settings sync turned off, every choice changed while it was off, and
    /// the switch turned back on after another device has moved on. The
    /// restart adopts iCloud first, and its pull is not read as an edit
    /// against the stores' agreement from before the stop. All three keys
    /// change, so whichever the pull writes first, the other two are still
    /// this device's when its notification arrives.
    @Test("Starting again after a stop takes iCloud's values and sends nothing")
    func restartSendsNothingStale() throws {
        let agreed: [String: Any] = [
            SettingsKey.tileProviderID: Constants.osm,
            SettingsKey.showsHikingRoutes: true,
            SettingsKey.savePhotosToLibrary: true,
        ]
        let defaults = try Self.defaults(holding: agreed)
        let store = InMemoryCloudSettingsStore(agreed)
        let mirror = SyncedSettingsMirror(defaults: defaults, store: store, notificationCenter: .default)
        mirror.start()
        defer { mirror.stop() }

        mirror.stop()
        defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)
        defaults.set(false, forKey: SettingsKey.showsHikingRoutes)
        defaults.set(false, forKey: SettingsKey.savePhotosToLibrary)
        store.receive(Constants.stadia, forKey: SettingsKey.tileProviderID)
        mirror.start()

        #expect(store.writes.isEmpty)
        Self.expectRemoteAdopted(in: defaults)
    }

    /// The other half of the same delivery: a choice made here is sent before
    /// its `set` returns, which is why an edit on the main thread is never
    /// left pending behind an incoming change.
    @Test("A choice made here is sent before its write returns")
    func localEditIsSentAtOnce() throws {
        let defaults = try Self.defaults(holding: Self.local)
        let store = InMemoryCloudSettingsStore(Self.local)
        let mirror = SyncedSettingsMirror(defaults: defaults, store: store, notificationCenter: .default)
        mirror.start()
        defer { mirror.stop() }

        defaults.set(Constants.thunderforest, forKey: SettingsKey.tileProviderID)

        #expect(store.object(forKey: SettingsKey.tileProviderID) as? String == Constants.thunderforest)
        #expect(store.writes == [SettingsKey.tileProviderID])
    }
}
