//
//  SyncedSettingsCloudChangeTests.swift
//  OpenHikesTests
//
//  What the mirror is told about a change decides how much of this device's
//  settings it may overwrite: the keys bound it, and the reason decides
//  whether iCloud wins outright.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Synced settings cloud change")
struct SyncedSettingsCloudChangeTests {
    @Test(
        "Each change reason the store sends is read",
        arguments: [
            (NSUbiquitousKeyValueStoreServerChange, SyncedSettingsCloudChange.Reason.server),
            (NSUbiquitousKeyValueStoreInitialSyncChange, .initialSync),
            (NSUbiquitousKeyValueStoreQuotaViolationChange, .quotaViolation),
            (NSUbiquitousKeyValueStoreAccountChange, .accountChange),
        ]
    )
    func readsReason(raw: Int, expected: SyncedSettingsCloudChange.Reason) {
        let change = SyncedSettingsCloudChange(Self.notification([
            NSUbiquitousKeyValueStoreChangeReasonKey: raw,
            NSUbiquitousKeyValueStoreChangedKeysKey: [SettingsKey.tileProviderID],
        ]))

        #expect(change.reason == expected)
        #expect(change.keys == [SettingsKey.tileProviderID])
    }

    /// A reason the store does not send today is reconciled key by key, over
    /// the keys it names, never treated as permission for iCloud to win
    /// everywhere.
    @Test("An unknown reason reads as a server change to the keys it names")
    func unknownReason() {
        let change = SyncedSettingsCloudChange(Self.notification([
            NSUbiquitousKeyValueStoreChangeReasonKey: 99,
            NSUbiquitousKeyValueStoreChangedKeysKey: [SettingsKey.showsHikingRoutes],
        ]))

        #expect(change.reason == .server)
        #expect(change.keys == [SettingsKey.showsHikingRoutes])
    }

    /// A notification that does not say what moved is reconciled over every
    /// synced key, by the same key-by-key rule.
    @Test("A missing userInfo reads as a server change to every synced key")
    func missingUserInfo() {
        let change = SyncedSettingsCloudChange(Notification(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: nil
        ))

        #expect(change.reason == .server)
        #expect(change.keys == Set(SyncedSetting.all.map(\.key)))
    }

    private static func notification(_ userInfo: [AnyHashable: Any]) -> Notification {
        Notification(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: userInfo
        )
    }
}
