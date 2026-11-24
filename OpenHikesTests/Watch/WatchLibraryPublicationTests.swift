//
//  WatchLibraryPublicationTests.swift
//  OpenHikesTests
//
//  The library and its two switches go to the watch as the session's
//  application context, and the session can refuse one. The phone used to
//  count the switches sent before the write, so a refused context left it
//  believing the watch had them, with nothing left pending to send again.
//  These refuse one write and accept the next, through the write the
//  coordinator hands in, and hold the publication to what the session took.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("The library as the watch was sent it")
struct WatchLibraryPublicationTests {
    private struct Refused: Error {}

    private static let catalog = SharedHikeCatalog(hikes: [])

    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "watch-library-publication-\(UUID().uuidString)"))
    }

    /// One refused write, a switch turned off before the next, and the next
    /// taken: the watch is sent the switch as it stands at that write.
    @Test("a refused context stays pending, and the next write carries the newer switch")
    func refusedThenFlushedWithNewerSwitch() throws {
        let defaults = try Self.defaults()
        var publication = WatchLibraryPublication()
        publication.offer(Self.catalog)

        let refused: Void? = try? publication.flush(defaults: defaults) { _ in throw Refused() }
        #expect(refused == nil, "precondition: the session refused the context")
        #expect(publication.isPending)
        #expect(publication.sentAutoPause == nil, "the watch was sent nothing")

        defaults.set(false, forKey: SettingsKey.autoPauseEnabled)
        let owed1 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(owed1)

        var written: [WatchLibraryDigest] = []
        try publication.flush(defaults: defaults) { written.append($0) }

        #expect(written.map(\.autoPauseEnabled) == [false])
        #expect(!publication.isPending)
        #expect(publication.sentAutoPause == false)
        #expect(publication.sentJunctionWarnings == SettingsDefault.junctionWarningsEnabled)
    }

    /// The case the old order lost: a switch the watch never got, and a
    /// notification with the same value finding nothing to send.
    @Test("a refused change of a switch is sent again, not taken as sent")
    func refusedSwitchChangeIsNotSent() throws {
        let defaults = try Self.defaults()
        var publication = WatchLibraryPublication()
        publication.offer(Self.catalog)
        try publication.flush(defaults: defaults) { _ in /* taken */ }
        #expect(publication.sentAutoPause == true)

        defaults.set(false, forKey: SettingsKey.autoPauseEnabled)
        let owed2 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(owed2)
        let refused: Void? = try? publication.flush(defaults: defaults) { _ in throw Refused() }
        #expect(refused == nil, "precondition: the session refused the context")

        #expect(publication.sentAutoPause == true, "what the watch still has")
        let owed3 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(owed3, "the same value is still owed")
        var written: [WatchLibraryDigest] = []
        try publication.flush(defaults: defaults) { written.append($0) }
        #expect(written.map(\.autoPauseEnabled) == [false])
        #expect(publication.sentAutoPause == false)
    }

    @Test("once taken, only a switch that moved makes the library pending again")
    func takenLibraryWaitsForAChange() throws {
        let defaults = try Self.defaults()
        var publication = WatchLibraryPublication()
        publication.offer(Self.catalog)
        try publication.flush(defaults: defaults) { _ in /* taken */ }

        let owed4 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(!owed4)
        var written = 0
        try publication.flush(defaults: defaults) { _ in written += 1 }
        #expect(written == 0, "nothing pending writes nothing")

        defaults.set(!SettingsDefault.junctionWarningsEnabled, forKey: SettingsKey.junctionWarningsEnabled)
        let owed5 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(owed5)
        try publication.flush(defaults: defaults) { _ in written += 1 }
        #expect(written == 1)
        #expect(publication.sentJunctionWarnings == !SettingsDefault.junctionWarningsEnabled)
    }

    @Test("nothing offered has nothing to send, whatever the switches do")
    func nothingOfferedSendsNothing() throws {
        let defaults = try Self.defaults()
        var publication = WatchLibraryPublication()

        defaults.set(false, forKey: SettingsKey.autoPauseEnabled)
        let owed6 = publication.switchesMayHaveChanged(defaults: defaults)
        #expect(!owed6)
        var written = 0
        try publication.flush(defaults: defaults) { _ in written += 1 }
        #expect(written == 0)
    }
}
