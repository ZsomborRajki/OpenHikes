//
//  WatchTrailSelectionTests.swift
//  OpenHikesSharedTests
//
//  A trail package that lands after the hiker has moved on, or after a newer
//  copy of the same trail — issue #867. The watch has no test bundle, so the
//  decision is here and ``WatchModel`` only asks it.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch trail selection")
struct WatchTrailSelectionTests {
    @Test("A then B asked for, B then A delivered: the watch keeps B")
    func lateAnswerForAnEarlierTrailIsDropped() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailA)
        selection.select(Fixture.trailB)
        var held: WatchTrailPackage?

        let b = Fixture.package(Fixture.trailB, at: 20)
        if selection.accepts(b, replacing: held) { held = b }
        let a = Fixture.package(Fixture.trailA, at: 10)
        if selection.accepts(a, replacing: held) { held = a }

        #expect(held == b)
    }

    @Test("the trail asked for is taken over a different one held")
    func wantedTrailReplacesAnotherHeld() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailB)

        // Older than what is held, and still taken: the stamps of two
        // different trails say nothing about which the hiker wants.
        #expect(selection.accepts(
            Fixture.package(Fixture.trailB, at: 10),
            replacing: Fixture.package(Fixture.trailA, at: 20)
        ))
    }

    @Test("an older copy of the trail held does not replace a newer one")
    func olderRevisionOfTheSameTrailIsDropped() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailA)
        let edited = Fixture.package(Fixture.trailA, at: 20, title: "Thumsee and Back")

        #expect(!selection.accepts(Fixture.package(Fixture.trailA, at: 10), replacing: edited))
    }

    @Test("a newer copy of the trail held replaces it, and so does one read at the same moment")
    func newerOrSimultaneousRevisionIsTaken() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailA)
        let held = Fixture.package(Fixture.trailA, at: 10)

        #expect(selection.accepts(Fixture.package(Fixture.trailA, at: 20, title: "Thumsee and Back"), replacing: held))
        #expect(selection.accepts(Fixture.package(Fixture.trailA, at: 10), replacing: held))
    }

    @Test("before anything is opened, any trail is taken, but an older copy of the one held is not")
    func noSelectionStillOrdersTheSameTrail() {
        let selection = WatchTrailSelection()
        let held = Fixture.package(Fixture.trailA, at: 20)

        #expect(selection.accepts(Fixture.package(Fixture.trailB, at: 10), replacing: held))
        #expect(selection.accepts(Fixture.package(Fixture.trailA, at: 10), replacing: nil))
        #expect(!selection.accepts(Fixture.package(Fixture.trailA, at: 10), replacing: held))
    }

    @Test("a new library re-asks for the trail wanted, not the one held")
    func digestRefreshesTheWantedTrail() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailB)
        let digest = Fixture.digest(Fixture.trailA, Fixture.trailB)

        #expect(selection.refreshTarget(holding: Fixture.package(Fixture.trailA, at: 10), in: digest) == Fixture.trailB)
    }

    @Test("with nothing opened, a new library re-asks for the trail held")
    func digestRefreshesTheHeldTrailWithoutASelection() {
        let digest = Fixture.digest(Fixture.trailA)

        #expect(WatchTrailSelection().refreshTarget(
            holding: Fixture.package(Fixture.trailA, at: 10),
            in: digest
        ) == Fixture.trailA)
        #expect(WatchTrailSelection().refreshTarget(holding: nil, in: digest) == nil)
    }

    @Test("a trail no longer on the list is not asked about")
    func digestWithoutTheTrailAsksNothing() {
        var selection = WatchTrailSelection()
        selection.select(Fixture.trailB)

        #expect(selection.refreshTarget(
            holding: Fixture.package(Fixture.trailA, at: 10),
            in: Fixture.digest(Fixture.trailA)
        ) == nil)
    }

    enum Fixture {
        static let trailA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") ?? UUID()
        static let trailB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") ?? UUID()
        static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

        static func package(
            _ hikeID: UUID,
            at seconds: TimeInterval,
            title: String = "Thumsee Loop"
        ) -> WatchTrailPackage {
            WatchTrailPackage(
                hikeID: hikeID,
                title: title,
                tintHex: "#2E7D32",
                totalDistanceMeters: 8420.5,
                points: [
                    WatchTrailPoint(latitude: 47.6961, longitude: 12.8543),
                    WatchTrailPoint(latitude: 47.6972, longitude: 12.8559),
                ],
                sentAt: epoch.addingTimeInterval(seconds)
            )
        }

        static func digest(_ hikeIDs: UUID...) -> WatchLibraryDigest {
            WatchLibraryDigest(
                hikes: hikeIDs.map { SharedHikeSummary(id: $0, name: "Trail", date: epoch, distanceMeters: 8420.5) },
                sentAt: epoch
            )
        }
    }
}

// swiftlint:enable no_magic_numbers
