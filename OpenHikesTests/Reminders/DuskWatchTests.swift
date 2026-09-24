//
//  DuskWatchTests.swift
//  OpenHikesTests
//
//  When a walk is said to end after dark, and — mostly — when it is not.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Dusk watch")
struct DuskWatchTests {
    private static let now = Date(timeIntervalSince1970: 1_758_000_000)
    private static let dusk = now.addingTimeInterval(2 * 3600)

    @Test("an estimate past civil dusk is said, once")
    func pastDuskIsSaidOnce() {
        var watch = DuskWatch()
        let late = Self.dusk.addingTimeInterval(600)

        let said1 = watch.observed(finishAt: late, civilDusk: Self.dusk, now: Self.now)

        #expect(said1)
        let said2 = watch.observed(finishAt: late, civilDusk: Self.dusk, now: Self.now.addingTimeInterval(60))
        #expect(!said2)
    }

    /// At the crossing, not with slack — the owner's decision.
    @Test("an estimate before dusk says nothing, however close")
    func beforeDuskIsQuiet() {
        var watch = DuskWatch()
        let said3 = watch.observed(finishAt: Self.dusk.addingTimeInterval(-1), civilDusk: Self.dusk, now: Self.now)
        #expect(!said3)
        let said4 = watch.observed(finishAt: Self.dusk, civilDusk: Self.dusk, now: Self.now)
        #expect(!said4)
    }

    /// The estimate swinging back and forth across dusk as the hiker speeds
    /// up and slows down is not news each time.
    @Test("an estimate that crosses back and forth is said once")
    func swingingEstimateIsSaidOnce() {
        var watch = DuskWatch()
        let late = Self.dusk.addingTimeInterval(60)
        let early = Self.dusk.addingTimeInterval(-60)
        var said = 0
        for (index, finish) in [late, early, late, early, late].enumerated() {
            let moment = Self.now.addingTimeInterval(Double(index) * 60)
            if watch.observed(finishAt: finish, civilDusk: Self.dusk, now: moment) { said += 1 }
        }
        #expect(said == 1)
    }

    @Test("a walk already in the dark is not told it is dark")
    func afterDuskIsQuiet() {
        var watch = DuskWatch()
        let pastDusk = Self.dusk.addingTimeInterval(60)
        let said5 = watch.observed(finishAt: pastDusk.addingTimeInterval(3600), civilDusk: Self.dusk, now: pastDusk)
        #expect(!said5)
    }

    /// A polar-summer day has no dusk, and that is a fact rather than a gap.
    @Test("no dusk is no warning")
    func noDuskIsQuiet() {
        var watch = DuskWatch()
        let said6 = watch.observed(finishAt: Self.now.addingTimeInterval(24 * 3600), civilDusk: nil, now: Self.now)
        #expect(!said6)
    }

    @Test("a new walk may be told again")
    func resetRearms() {
        var watch = DuskWatch()
        let late = Self.dusk.addingTimeInterval(600)
        let said7 = watch.observed(finishAt: late, civilDusk: Self.dusk, now: Self.now)
        #expect(said7)
        watch.reset()
        let said8 = watch.observed(finishAt: late, civilDusk: Self.dusk, now: Self.now)
        #expect(said8)
    }
}
