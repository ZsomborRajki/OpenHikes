//
//  JunctionAnnouncerTests.swift
//  OpenHikesSharedTests
//
//  When the phone speaks and the watch taps about a junction. Both devices
//  ask ``JunctionAnnouncer``, and neither can be listened to by a suite, so
//  the whole rule is held here.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Junction announcer")
struct JunctionAnnouncerTests {
    private static let fork = TrailJunction(distanceMeters: 1000, towardsEnd: .keepLeft, towardsStart: .turnRight)

    /// Walks `announcer` from `start` to `end` a metre at a time and collects
    /// every cue, with where it was said.
    private static func walk(
        _ announcer: inout JunctionAnnouncer,
        from start: Double,
        to end: Double
    ) -> [(at: Double, cue: JunctionCue)] {
        let step: Double = end >= start ? 1 : -1
        return stride(from: start, through: end, by: step).compactMap { distance in
            announcer.advance(to: distance, isOnTrail: true).map { (distance, $0) }
        }
    }

    @Test("a hiker walking up to a junction hears its distance, then what to do there, once each")
    func twoCuesOnce() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork])

        let cues = Self.walk(&announcer, from: 800, to: 1050)

        #expect(cues.count == 2)
        #expect(cues.first?.cue.maneuver == .keepLeft)
        #expect(cues.first?.cue.metersAhead == 150)
        #expect(cues.first?.at == 850)
        #expect(cues.last?.cue == JunctionCue(junctionIndex: 0, maneuver: .keepLeft, metersAhead: nil))
        #expect(cues.last?.at == 970)
    }

    @Test("nothing is said until the matches say which way the hiker is going")
    func silentUntilDirectionIsKnown() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork])

        #expect(announcer.advance(to: 900, isOnTrail: true) == nil)
        #expect(announcer.advance(to: 905, isOnTrail: true) == nil)
        #expect(announcer.direction == nil)
        let cue = announcer.advance(to: 910, isOnTrail: true)

        #expect(announcer.direction == .towardsEnd)
        #expect(cue?.metersAhead == 90)
    }

    @Test("a direction the caller already knows is used from the first fix")
    func seededDirectionSpeaksAtOnce() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork], direction: .towardsEnd)

        #expect(announcer.advance(to: 880, isOnTrail: true)?.metersAhead == 120)
    }

    @Test("a hiker first placed close to the junction hears only what to do there")
    func lateFirstFixSkipsTheDistance() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork], direction: .towardsEnd)

        let cues = Self.walk(&announcer, from: 950, to: 1010)

        #expect(cues.map(\.cue.metersAhead) == [nil])
        #expect(cues.first?.at == 970)
    }

    @Test("walking the line backwards measures back and says the other direction's advice")
    func reverseDirection() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork])

        let cues = Self.walk(&announcer, from: 1200, to: 950)

        #expect(cues.map(\.cue.maneuver) == [.turnRight, .turnRight])
        #expect(cues.first?.at == 1150)
        #expect(cues.first?.cue.metersAhead == 150)
        #expect(cues.last?.at == 1030)
    }

    @Test("a junction with nothing to say walking this way is passed over for the next")
    func silentJunctionIsSkipped() {
        let straightOn = TrailJunction(distanceMeters: 950, towardsEnd: nil, towardsStart: .keepRight)
        var announcer = JunctionAnnouncer(junctions: [straightOn, Self.fork], direction: .towardsEnd)

        let cues = Self.walk(&announcer, from: 800, to: 1050)

        #expect(cues.map(\.cue.junctionIndex) == [1, 1])
    }

    @Test("a fix off the trail says nothing and does not move the direction")
    func offTrailIsSilent() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork])
        _ = announcer.advance(to: 880, isOnTrail: true)

        #expect(announcer.advance(to: 990, isOnTrail: false) == nil)
        #expect(announcer.direction == nil)
    }

    @Test("GPS wandering around one spot at a fork does not turn the hiker round")
    func jitterKeepsTheDirection() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork], direction: .towardsEnd)
        _ = Self.walk(&announcer, from: 950, to: 975)

        for distance in [972.0, 968, 974, 966, 971] {
            #expect(announcer.advance(to: distance, isOnTrail: true) == nil)
        }
        #expect(announcer.direction == .towardsEnd)
    }

    @Test("a hiker who turns back at the junction hears the other way's advice")
    func turningBackHearsTheReturn() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork], direction: .towardsEnd)
        _ = Self.walk(&announcer, from: 800, to: 1100)

        let cues = Self.walk(&announcer, from: 1100, to: 950)

        // Once ten metres back have said which way they are going.
        #expect(cues.map(\.cue.maneuver) == [.turnRight, .turnRight])
        #expect(cues.first?.at == 1090)
        #expect(cues.first?.cue.metersAhead == 90)
    }

    @Test("a second pass, once the hiker has been well away, is said again")
    func laterPassIsSaidAgain() {
        var announcer = JunctionAnnouncer(junctions: [Self.fork], direction: .towardsEnd)
        _ = Self.walk(&announcer, from: 800, to: 1300)
        _ = Self.walk(&announcer, from: 1300, to: 700)

        let cues = Self.walk(&announcer, from: 700, to: 1050)

        #expect(cues.count == 2)
    }

    @Test("two junctions close together are said in the order the hiker meets them")
    func closeJunctionsInOrder() {
        let turn = TrailJunction(distanceMeters: 1025, towardsEnd: .turnRight, towardsStart: .turnLeft)
        var announcer = JunctionAnnouncer(junctions: [turn, Self.fork], direction: .towardsEnd)

        let cues = Self.walk(&announcer, from: 800, to: 1050)

        #expect(cues.map(\.cue.maneuver) == [.keepLeft, .keepLeft, .turnRight])
        #expect(cues.map(\.cue.isImminent) == [false, true, true])
        // The turn after the fork is said at the fork, not before it, where
        // the hiker would take it at the fork.
        #expect(cues.map(\.at) == [850, 970, 1000])
    }

    @Test("walking back the same way, the next junction still waits for the one being reached")
    func closeJunctionsInOrderBackwards() {
        let turn = TrailJunction(distanceMeters: 975, towardsEnd: .turnRight, towardsStart: .turnLeft)
        var announcer = JunctionAnnouncer(junctions: [turn, Self.fork], direction: .towardsStart)

        let cues = Self.walk(&announcer, from: 1200, to: 950)

        #expect(cues.map(\.cue.maneuver) == [.turnRight, .turnRight, .turnLeft])
        #expect(cues.map(\.cue.junctionIndex) == [1, 1, 0])
        #expect(cues.map(\.at) == [1150, 1030, 1000])
    }

    @Test("junctions handed in any order are kept by distance")
    func junctionsAreSorted() {
        let early = TrailJunction(distanceMeters: 200, towardsEnd: .turnLeft, towardsStart: nil)
        let announcer = JunctionAnnouncer(junctions: [Self.fork, early])

        #expect(announcer.junctions.map(\.distanceMeters) == [200, 1000])
    }

    @Test("the distance is said to the nearest ten metres, or fifty feet")
    func roundedDistance() {
        let cue = JunctionCue(junctionIndex: 0, maneuver: .keepLeft, metersAhead: 137)
        let metric = Locale(identifier: "de_DE")
        let imperial = Locale(identifier: "en_US")

        #expect(cue.roundedDistance(locale: metric) == Measurement(value: 140, unit: UnitLength.meters))
        #expect(cue.roundedDistance(locale: imperial) == Measurement(value: 450, unit: UnitLength.feet))
        #expect(JunctionCue(junctionIndex: 0, maneuver: .straight, metersAhead: 2)
            .roundedDistance(locale: metric)?.value == 10)
        #expect(JunctionCue(junctionIndex: 0, maneuver: .straight, metersAhead: nil)
            .roundedDistance(locale: metric) == nil)
    }

    @Test("a maneuver's side is the side the trail goes to")
    func maneuverSides() {
        #expect(JunctionManeuver.allCases.filter { $0.side == .left } == [.keepLeft, .sharpLeft, .turnLeft])
        #expect(JunctionManeuver.allCases.filter { $0.side == .right } == [.keepRight, .sharpRight, .turnRight])
        #expect(JunctionManeuver.straight.side == .ahead)
    }
}

// swiftlint:enable no_magic_numbers
