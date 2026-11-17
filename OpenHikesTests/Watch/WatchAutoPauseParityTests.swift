//
//  WatchAutoPauseParityTests.swift
//  OpenHikesTests
//
//  Holds the watch's Auto-Pause to the phone's: one switch, sent across with
//  the library, with one default, and one allowance of fixes held at a stop.
//
//  The watch reads the switch only from what the phone sends, and has no
//  test bundle of its own (*The watch app* in AGENTS.md), so the phone's half
//  is asserted here and the watch's in `WatchAutoPauseTests`.
//

import Foundation
@testable import OpenHikes
@testable import OpenHikesShared
import Testing

@Suite("Watch auto-pause parity")
struct WatchAutoPauseParityTests {
    @Test("a watch told nothing has Auto-Pause on, as the phone's switch starts")
    func defaultsAgree() {
        #expect(WatchLibraryDigest.empty.isAutoPauseOn == SettingsDefault.autoPauseEnabled)
    }

    @Test("the library the watch is sent carries the phone's switch")
    func libraryCarriesTheSwitch() throws {
        let defaults = try #require(UserDefaults(suiteName: "WatchAutoPauseParityTests-\(UUID().uuidString)"))
        let catalog = SharedHikeCatalog(hikes: [])
        #expect(WatchSessionCoordinator.digest(of: catalog, defaults: defaults).autoPauseEnabled == true)

        defaults.set(false, forKey: SettingsKey.autoPauseEnabled)
        #expect(WatchSessionCoordinator.digest(of: catalog, defaults: defaults).autoPauseEnabled == false)
    }

    @Test("a stop holds as many fixes on the watch as on the phone")
    func heldFixesAgree() {
        #expect(WatchAutoPause<Int>.maximumHeldFixes == RecordingAutoPause.maximumHeldFixes)
    }
}
