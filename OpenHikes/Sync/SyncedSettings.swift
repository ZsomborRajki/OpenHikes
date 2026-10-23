//
//  SyncedSettings.swift
//  OpenHikes
//
//  The handful of preferences that follow the person rather than the phone,
//  carried by `NSUbiquitousKeyValueStore`.
//
//  A separate mechanism from the hikes on purpose. The key-value store is
//  Apple's answer for exactly this shape of data — a kilobyte of small,
//  last-writer-wins settings — and it needs no schema at all. Putting two
//  settings into the mirrored SwiftData store would have meant giving them a
//  model, a record type and a permanent CloudKit column apiece to earn
//  nothing.
//
//  The list is short and it is an allowlist, because the interesting decision
//  here is what *doesn't* travel:
//
//  - ``SettingsKey/backgroundTrackingEnabled`` stays put. It is a claim about
//    a permission this device has been granted; syncing it on would leave a
//    second phone with the switch showing on and no Always-location authority
//    behind it, which is a lie the settings screen would then have to explain.
//  - ``SettingsKey/lastSelectedHikeID`` stays put. It is where *this* device
//    is in the app, and it is what a background relaunch matches fixes
//    against — a phone in a drawer would start tracking whatever the phone in
//    a pocket was looking at.
//  - ``SettingsKey/lastMatchedDistance`` stays put, for the same reason and
//    more so: it is a continuity reference for one device's walk.
//

import Foundation
import os

/// A setting's value, typed rather than `Any`, so that the merge below is a
/// pure function over `Equatable` values and can be tested without either
/// store.
nonisolated enum SyncedSettingValue: Equatable, Sendable {
    case boolean(Bool)
    case text(String)
}

/// One key that travels, and what shape its value is.
nonisolated struct SyncedSetting: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case boolean
        case text
    }

    let key: String
    let kind: Kind

    /// The allowlist. Spelled with ``SettingsKey``'s own constants rather than
    /// with copies of their strings: these are the same storage contract, and
    /// a second copy of a key is a second thing to get wrong.
    static let all: [Self] = [
        Self(key: SettingsKey.tileProviderID, kind: .text),
        Self(key: SettingsKey.showsHikingRoutes, kind: .boolean),
        Self(key: SettingsKey.savePhotosToLibrary, kind: .boolean),
    ]
}

/// Which way a difference between the two stores should be resolved.
///
/// Pure, and separated from either store, because "last writer wins" has one
/// awkward case — a first launch on a new device, where local is merely the
/// default and iCloud holds the user's real choice — and that case is worth a
/// test rather than a comment.
nonisolated enum SyncedSettingsMerge {
    /// At startup iCloud wins wherever it has an opinion.
    ///
    /// A device that has just been restored has defaults, not preferences; a
    /// value in iCloud was chosen by the person, on some device, at some point.
    /// Preferring the local value here would mean a new phone quietly resetting
    /// a choice made on the old one — and then, worse, pushing that reset back
    /// up.
    static func adopting(
        local: [String: SyncedSettingValue],
        remote: [String: SyncedSettingValue]
    ) -> (pull: [String: SyncedSettingValue], push: [String: SyncedSettingValue]) {
        var pull: [String: SyncedSettingValue] = [:]
        var push: [String: SyncedSettingValue] = [:]
        for setting in SyncedSetting.all {
            let localValue = local[setting.key]
            let remoteValue = remote[setting.key]
            switch (localValue, remoteValue) {
            case (_, .some(let value)) where localValue != remoteValue:
                pull[setting.key] = value
            case (.some(let value), .none):
                push[setting.key] = value
            default:
                continue
            }
        }
        return (pull, push)
    }

    /// After startup, a local change sends only what this device edited: the
    /// synced values that differ from `baseline`, the value each key held
    /// when the two stores last agreed.
    ///
    /// Not every local value that differs from iCloud's. A local value that
    /// still matches the baseline is stale rather than chosen, and differs
    /// from iCloud only because another device's change has not been pulled
    /// yet; sending it would undo that change.
    static func pushing(
        local: [String: SyncedSettingValue],
        baseline: [String: SyncedSettingValue]
    ) -> [String: SyncedSettingValue] {
        var push: [String: SyncedSettingValue] = [:]
        for setting in SyncedSetting.all {
            guard let value = local[setting.key], value != baseline[setting.key] else { continue }
            push[setting.key] = value
        }
        return push
    }

    /// After startup, an incoming change to `keys` takes iCloud's value,
    /// except where this device has edited the same key and not yet sent it.
    ///
    /// That edit has not reached the store yet, so it is the later write to
    /// it, and the store's own last-writer-wins would keep it over the change
    /// that arrived first. It is sent instead of overwritten. Keys outside
    /// `keys` are left alone, so a pending edit to one setting survives a
    /// change to another.
    static func reconciling(
        keys: Set<String>,
        local: [String: SyncedSettingValue],
        remote: [String: SyncedSettingValue],
        baseline: [String: SyncedSettingValue]
    ) -> (pull: [String: SyncedSettingValue], push: [String: SyncedSettingValue]) {
        var pull: [String: SyncedSettingValue] = [:]
        var push: [String: SyncedSettingValue] = [:]
        for setting in SyncedSetting.all where keys.contains(setting.key) {
            let localValue = local[setting.key]
            let remoteValue = remote[setting.key]
            if let value = localValue, value != baseline[setting.key] {
                if value != remoteValue { push[setting.key] = value }
            } else if let value = remoteValue, value != localValue {
                pull[setting.key] = value
            }
        }
        return (pull, push)
    }
}

/// Keeps the allowlisted keys the same on every device signed into one Apple
/// Account.
@MainActor
final class SyncedSettingsMirror {

    private let defaults: UserDefaults
    private let store: any SyncedSettingsCloudStore
    private let notificationCenter: NotificationCenter
    private var observers: [any NSObjectProtocol] = []
    /// Each synced key's value as the two stores last agreed on it.
    ///
    /// This is how the mirror knows which side edited a key, which the two
    /// stores alone cannot say: a local value that differs from it is an edit
    /// made here, and one that matches it is merely stale. Without it, any
    /// defaults notification pushed every local value that differed from
    /// iCloud's, so an unrelated write that ran before another device's
    /// change had been pulled sent the old choice back up over the new one.
    /// It also replaces a "the mirror is writing" flag as the loop guard,
    /// because the notifications are delivered on `.main`, a runloop turn
    /// after any such flag would have come down: the mirror's own write
    /// matches the baseline by the time its notification arrives, so it sends
    /// nothing back.
    private var baseline: [String: SyncedSettingValue] = [:]

    init(
        defaults: UserDefaults,
        store: any SyncedSettingsCloudStore = NSUbiquitousKeyValueStore.default,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.store = store
        self.notificationCenter = notificationCenter
    }

    var isRunning: Bool { !observers.isEmpty }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(
            notificationCenter.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { [weak self] notification in
                let change = SyncedSettingsCloudChange(notification)
                MainActor.assumeIsolated { self?.cloudDidChange(change) }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.defaultsDidChange() }
            }
        )
        // `synchronize()` only flushes the in-memory copy to disk; it does not
        // wait on the network. It is here because the first read after launch
        // is the one that decides whether a restored device adopts the user's
        // choices or overwrites them.
        store.synchronize()
        adopt()
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    // MARK: - Directions

    /// Remote-first, over the whole allowlist; see
    /// ``SyncedSettingsMerge/adopting(local:remote:)``.
    private func adopt() {
        let plan = SyncedSettingsMerge.adopting(local: localValues(), remote: remoteValues())
        apply(plan.pull, to: defaults)
        write(plan.push, to: store)
        baseline = localValues()
    }

    /// iCloud's store said something changed.
    ///
    /// A new account, or the first download after joining one, is the
    /// restored-device case again and adopts remote-first. Anything else is
    /// confined to the keys the notification names, so that pulling one
    /// setting cannot overwrite a pending local edit to another.
    func cloudDidChange(_ change: SyncedSettingsCloudChange) {
        switch change.reason {
        case .initialSync, .accountChange:
            adopt()
        case .server, .quotaViolation:
            let plan = SyncedSettingsMerge.reconciling(
                keys: change.keys,
                local: localValues(),
                remote: remoteValues(),
                baseline: baseline
            )
            apply(plan.pull, to: defaults)
            write(plan.push, to: store)
            let local = localValues()
            for setting in SyncedSetting.all where change.keys.contains(setting.key) {
                baseline[setting.key] = local[setting.key]
            }
        }
    }

    /// Something in the defaults suite changed, synced or not: sends only the
    /// synced values that moved since the stores last agreed.
    func defaultsDidChange() {
        let local = localValues()
        write(SyncedSettingsMerge.pushing(local: local, baseline: baseline), to: store)
        baseline = local
    }

    // MARK: - Reading and writing

    private func localValues() -> [String: SyncedSettingValue] {
        var values: [String: SyncedSettingValue] = [:]
        for setting in SyncedSetting.all {
            // `object(forKey:)` rather than the typed accessors, because those
            // cannot tell "false" from "never set" — and the difference decides
            // whether this device has an opinion to push.
            guard defaults.object(forKey: setting.key) != nil else { continue }
            switch setting.kind {
            case .boolean:
                values[setting.key] = .boolean(defaults.bool(forKey: setting.key))
            case .text:
                guard let text = defaults.string(forKey: setting.key) else { continue }
                values[setting.key] = .text(text)
            }
        }
        return values
    }

    private func remoteValues() -> [String: SyncedSettingValue] {
        var values: [String: SyncedSettingValue] = [:]
        for setting in SyncedSetting.all {
            let object = store.object(forKey: setting.key)
            switch setting.kind {
            case .boolean:
                guard let flag = object as? Bool else { continue }
                values[setting.key] = .boolean(flag)
            case .text:
                guard let text = object as? String else { continue }
                values[setting.key] = .text(text)
            }
        }
        return values
    }

    /// Writes only what actually differs.
    ///
    /// A write that changes nothing posts no notification, so the steady
    /// state stays silent in both stores; ``baseline`` is what stops a write
    /// that does change something from coming back.
    private func apply(
        _ values: [String: SyncedSettingValue],
        to defaults: UserDefaults
    ) {
        let current = localValues()
        for (key, value) in values where current[key] != value {
            switch value {
            case .boolean(let flag): defaults.set(flag, forKey: key)
            case .text(let text): defaults.set(text, forKey: key)
            }
        }
    }

    private func write(
        _ values: [String: SyncedSettingValue],
        to store: any SyncedSettingsCloudStore
    ) {
        let current = remoteValues()
        for (key, value) in values where current[key] != value {
            switch value {
            case .boolean(let flag): store.set(flag, forKey: key)
            case .text(let text): store.set(text, forKey: key)
            }
        }
    }
}
