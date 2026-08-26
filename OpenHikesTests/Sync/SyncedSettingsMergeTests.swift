//
//  SyncedSettingsMergeTests.swift
//  OpenHikesTests
//
//  "Last writer wins" has one awkward case, and it is the case that matters
//  most: a phone taken out of its box has defaults, not preferences.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Synced settings merge")
struct SyncedSettingsMergeTests {
    private enum Constants {
        static let stadia = "stadia.outdoors"
        static let osm = "openstreetmap"
    }

    /// The restored-device case. Local is a default the app chose; remote is a
    /// choice the person made. Preferring local would quietly reset it — and
    /// then push the reset back up to every other device.
    @Test("iCloud's value wins where the two disagree")
    func remoteWinsOnDisagreement() {
        let result = SyncedSettingsMerge.adopting(
            local: [SettingsKey.tileProviderID: .text(Constants.osm)],
            remote: [SettingsKey.tileProviderID: .text(Constants.stadia)]
        )

        #expect(result.pull[SettingsKey.tileProviderID] == .text(Constants.stadia))
        #expect(result.push.isEmpty)
    }

    /// The first-device case: nothing is up there yet, so this device's
    /// settings are the only opinion in existence.
    @Test("A local value iCloud has never seen is pushed")
    func localValueIsPushedWhenRemoteIsEmpty() {
        let result = SyncedSettingsMerge.adopting(
            local: [
                SettingsKey.tileProviderID: .text(Constants.stadia),
                SettingsKey.savePhotosToLibrary: .boolean(true),
            ],
            remote: [:]
        )

        #expect(result.pull.isEmpty)
        #expect(result.push[SettingsKey.tileProviderID] == .text(Constants.stadia))
        #expect(result.push[SettingsKey.savePhotosToLibrary] == .boolean(true))
    }

    /// The steady state, which is almost every launch: nothing to say in
    /// either direction, and so nothing written to either store.
    @Test("Agreement moves nothing")
    func agreementIsSilent() {
        let both: [String: SyncedSettingValue] = [
            SettingsKey.tileProviderID: .text(Constants.stadia),
            SettingsKey.savePhotosToLibrary: .boolean(false),
        ]

        let result = SyncedSettingsMerge.adopting(local: both, remote: both)

        #expect(result.pull.isEmpty)
        #expect(result.push.isEmpty)
    }

    @Test("A key neither store has stays absent")
    func absentKeysStayAbsent() {
        let result = SyncedSettingsMerge.adopting(local: [:], remote: [:])

        #expect(result.pull.isEmpty)
        #expect(result.push.isEmpty)
    }

    /// The allowlist is the feature. A key that describes *this* device — a
    /// granted location permission, where this phone is in the app — must not
    /// be able to travel just because someone added it to `SettingsKey`.
    @Test("Only the allowlisted keys are considered")
    func nonAllowlistedKeysAreIgnored() {
        let result = SyncedSettingsMerge.adopting(
            local: [SettingsKey.backgroundTrackingEnabled: .boolean(true)],
            remote: [SettingsKey.lastSelectedHikeID: .text(UUID().uuidString)]
        )

        #expect(result.pull.isEmpty)
        #expect(result.push.isEmpty)
    }

    @Test("The allowlist holds exactly the device-independent preferences")
    func allowlistContents() {
        let keys = Set(SyncedSetting.all.map(\.key))

        #expect(keys == [SettingsKey.tileProviderID, SettingsKey.savePhotosToLibrary])
        #expect(!keys.contains(SettingsKey.backgroundTrackingEnabled))
        #expect(!keys.contains(SettingsKey.lastSelectedHikeID))
        #expect(!keys.contains(SettingsKey.lastMatchedDistance))
    }
}
