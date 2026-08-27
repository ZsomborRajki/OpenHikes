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
}

/// Keeps the allowlisted keys the same on every device signed into one Apple
/// Account.
@MainActor
final class SyncedSettingsMirror {
    private static let logger = Logger(subsystem: "OpenHikes", category: "CloudSync")

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observers: [any NSObjectProtocol] = []
    /// Raised while this type is the one writing to `UserDefaults`.
    ///
    /// A backstop rather than the loop guard, and only that: the observers
    /// below are registered on `.main` rather than with `queue: nil`, so
    /// `UserDefaults.didChangeNotification` is delivered a runloop turn later
    /// — by which time this has already come down. What actually stops the two
    /// stores talking to each other forever is that ``apply(_:to:)`` and
    /// ``write(_:to:)`` only write a value that differs, so the round trip
    /// converges after one pass.
    private var isMirroring = false

    init(
        defaults: UserDefaults,
        store: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.store = store
    }

    var isRunning: Bool { !observers.isEmpty }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pullFromCloud() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushToCloud() }
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
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    // MARK: - Directions

    private func adopt() {
        let plan = SyncedSettingsMerge.adopting(local: localValues(), remote: remoteValues())
        apply(plan.pull, to: defaults)
        write(plan.push, to: store)
    }

    private func pullFromCloud() {
        apply(remoteValues(), to: defaults)
    }

    private func pushToCloud() {
        guard !isMirroring else { return }
        write(localValues(), to: store)
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
            guard store.object(forKey: setting.key) != nil else { continue }
            switch setting.kind {
            case .boolean:
                values[setting.key] = .boolean(store.bool(forKey: setting.key))
            case .text:
                guard let text = store.string(forKey: setting.key) else { continue }
                values[setting.key] = .text(text)
            }
        }
        return values
    }

    /// Writes only what actually differs.
    ///
    /// The guard is what stops the two observers above talking to each other
    /// forever: a write that changes nothing posts no notification, and a
    /// write that does is one the other side will find equal and leave alone.
    private func apply(
        _ values: [String: SyncedSettingValue],
        to defaults: UserDefaults
    ) {
        let current = localValues()
        isMirroring = true
        defer { isMirroring = false }
        for (key, value) in values where current[key] != value {
            switch value {
            case .boolean(let flag): defaults.set(flag, forKey: key)
            case .text(let text): defaults.set(text, forKey: key)
            }
        }
    }

    private func write(
        _ values: [String: SyncedSettingValue],
        to store: NSUbiquitousKeyValueStore
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
