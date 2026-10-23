//
//  InMemoryCloudSettingsStore.swift
//  OpenHikesTests
//
//  iCloud's key-value store as a dictionary, so that a suite can change "the
//  cloud" without its notification having arrived yet, which is the window
//  every lost update in `SyncedSettingsMirror` lives in.
//

import Foundation
@testable import OpenHikes

final class InMemoryCloudSettingsStore: SyncedSettingsCloudStore {
    private(set) var values: [String: Any] = [:]
    /// Every write the mirror made, in order, so a suite can prove one did not
    /// happen as well as read the result.
    private(set) var writes: [String] = []

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
        writes.append(key)
    }

    func synchronize() -> Bool { true }

    /// Another device's write, landed in the store before its notification.
    func receive(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    /// A different Apple Account's store, swapped in wholesale.
    func replaceAll(with values: [String: Any]) {
        self.values = values
    }
}
