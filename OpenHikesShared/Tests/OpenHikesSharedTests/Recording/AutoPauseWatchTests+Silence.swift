//
//  AutoPauseWatchTests+Silence.swift
//  OpenHikesSharedTests
//
//  When a silence is a stop (#1470). A bench under open sky and a tunnel
//  both deliver no fix, so the clock can call a stop only on evidence that
//  the hiker stood still from the start of the silence: motion that said so
//  from about the last fix, or fixes before it that showed the hiker
//  standing. Anything heard walked or ridden in it leaves it to the fix that
//  ends it.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

extension AutoPauseWatchTests {
    /// At a metre a second a fix 8 m loose stays in one stop's area for
    /// thirty seconds before the next area begins, which is as long as the
    /// recorder takes to call a hiker standing. Being in the area is not
    /// standing: the walk covered 30 m of it.
    @Test("a tunnel entered at a steady walk is not a stop, with or without motion")
    func tunnelAfterAWalk() {
        for motion in [AutoPauseWatch.Motion.unknown, .onFoot] {
            var watch = AutoPauseWatch()
            #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 8, motion: motion)).isEmpty)

            #expect(watch.tick(at: Self.time(340), motion: motion) == nil, "motion \(motion)")
            #expect(watch.tick(at: Self.time(900), motion: motion) == nil, "motion \(motion)")
            #expect(watch.observe(Self.fix(north: 470, at: 470, motion: motion)) == nil, "motion \(motion)")
            #expect(!watch.isStopped)
        }
    }

    /// The fixes before the silence showed the hiker standing, and then
    /// motion says they are walking: a shop with no signal inside, or a
    /// tunnel entered after a look at the map. Whatever motion says after,
    /// the fix that ends the silence decides.
    @Test("motion on foot or carried during a silence leaves it to the fix that ends it")
    func motionOverrulesStanding() {
        for motion in [AutoPauseWatch.Motion.onFoot, .carried] {
            var watch = AutoPauseWatch()
            let approach = Self.walk(from: 0, at: 0, fixes: 5)
            let settling = [Self.fix(north: 43, at: 55), Self.fix(north: 41, at: 75)]
            #expect(Self.events(&watch, observing: approach + settling).isEmpty)

            #expect(watch.tick(at: Self.time(80), motion: motion) == nil, "motion \(motion)")
            #expect(watch.tick(at: Self.time(100), motion: .stationary) == nil, "motion \(motion)")
            #expect(watch.tick(at: Self.time(400), motion: .stationary) == nil, "motion \(motion)")
            #expect(watch.tick(at: Self.time(420), motion: .unknown) == nil, "motion \(motion)")
            #expect(watch.observe(Self.fix(north: 42, at: 430)) == .stopped(since: Self.time(40)))
        }
    }

    /// Core Motion answers with low confidence now and then while a phone
    /// lies still.
    @Test("a low-confidence answer in the middle of a sit-down keeps it a stop")
    func lowConfidenceWhileStill() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 5, motion: .onFoot)).isEmpty)

        #expect(watch.tick(at: Self.time(60), motion: .stationary) == nil)
        #expect(watch.tick(at: Self.time(200), motion: .unknown) == nil)
        #expect(watch.tick(at: Self.time(340), motion: .unknown) == .stopped(since: Self.time(40)))
    }

    @Test("a walk that stood still and walked on before the silence is not a stop")
    func standingThenWalkingOn() {
        var watch = AutoPauseWatch()
        let approach = Self.walk(from: 0, at: 0, fixes: 5)
        let standing = [Self.fix(north: 41, at: 60), Self.fix(north: 42, at: 80)]
        let walkingOn = [Self.fix(north: 52, at: 90), Self.fix(north: 62, at: 100)]
        #expect(Self.events(&watch, observing: approach + standing + walkingOn).isEmpty)

        #expect(watch.tick(at: Self.time(400), motion: .unknown) == nil, "the last fixes showed a walk")
    }

    /// Motion said on foot at the last fix and nothing else until the hiker
    /// halted, four minutes into the tunnel.
    @Test("a silence motion calls still only minutes into it is not a stop")
    func stillOnlyMinutesIn() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 8, motion: .onFoot)).isEmpty)

        #expect(watch.tick(at: Self.time(310), motion: .stationary) == nil)
        #expect(watch.tick(at: Self.time(900), motion: .stationary) == nil)
        #expect(watch.observe(Self.fix(north: 560, at: 960, motion: .onFoot)) == nil)
        #expect(!watch.isStopped)
    }

    /// The tunnel walked on foot, a halt inside it, and the walk out.
    @Test("a silence motion heard walked is not a stop when motion later says still")
    func walkedThenHalted() {
        var watch = AutoPauseWatch()
        #expect(Self.events(&watch, observing: Self.walk(from: 0, at: 0, fixes: 8, motion: .onFoot)).isEmpty)

        #expect(watch.tick(at: Self.time(100), motion: .stationary) == nil, "a moment's halt at the tunnel mouth")
        #expect(watch.tick(at: Self.time(120), motion: .onFoot) == nil)
        #expect(watch.tick(at: Self.time(550), motion: .stationary) == nil)
        #expect(watch.observe(Self.fix(north: 560, at: 620, motion: .onFoot)) == nil)
        #expect(!watch.isStopped)
    }
}

// swiftlint:enable no_magic_numbers
