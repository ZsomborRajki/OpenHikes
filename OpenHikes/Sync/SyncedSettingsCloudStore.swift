//
//  SyncedSettingsCloudStore.swift
//  OpenHikes
//
//  The two things ``SyncedSettingsMirror`` takes from iCloud's key-value
//  store: the store itself, narrowed to the three calls the mirror makes, and
//  what one of its change notifications says.
//
//  Both exist so that a suite can put the two stores' notifications in any
//  order it likes. The real store is real iCloud even in a test host (see
//  *Deliberate test seams* in AGENTS.md), and its notifications arrive when the
//  system decides, so the orderings that lose a preference cannot be staged
//  against it at all.
//

import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the settings mirror uses.
protocol SyncedSettingsCloudStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: SyncedSettingsCloudStore {}

/// What one `didChangeExternallyNotification` reports, reduced to a `Sendable`
/// value before it leaves the notification's closure.
nonisolated struct SyncedSettingsCloudChange: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// Another device wrote, and the server passed it on.
        case server
        /// The first download since this device joined the account has
        /// arrived, and any write made here before it was discarded.
        case initialSync
        /// This device's own writes went over the store's quota.
        case quotaViolation
        /// A different Apple Account's store has replaced this one.
        case accountChange
    }

    /// Every synced key, which is what a notification that does not name its
    /// keys is taken to mean.
    static let allKeys = Set(SyncedSetting.all.map(\.key))

    let reason: Reason
    /// The keys the store says moved.
    let keys: Set<String>

    init(reason: Reason, keys: Set<String> = allKeys) {
        self.reason = reason
        self.keys = keys
    }

    /// Reads the notification's `userInfo`. A reason the store does not send
    /// today reads as `.server`, so it is reconciled key by key rather than
    /// allowed to overwrite a local choice wholesale.
    init(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        switch userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
        case NSUbiquitousKeyValueStoreInitialSyncChange: reason = .initialSync
        case NSUbiquitousKeyValueStoreQuotaViolationChange: reason = .quotaViolation
        case NSUbiquitousKeyValueStoreAccountChange: reason = .accountChange
        default: reason = .server
        }
        keys = (userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]).map(Set.init) ?? Self.allKeys
    }
}
