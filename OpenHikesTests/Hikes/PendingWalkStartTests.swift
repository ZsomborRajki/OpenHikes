//
//  PendingWalkStartTests.swift
//  OpenHikesTests
//
//  When a proposed walk becomes a walk, and what it is dated from. Pure
//  values: the session that holds a proposal is
//  `TrailWalkSessionTests+AutoStart`'s subject.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Pending walk start")
struct PendingWalkStartTests {
    private let origin = Date(timeIntervalSince1970: 1_750_000_000)

    /// A proposal on a five-kilometre route — by default one between two
    /// places four kilometres apart, `endsApartMeters` 0 for a loop or an
    /// out-and-back.
    private func proposal(at distance: Double = 1000, endsApartMeters: Double = 4000) -> PendingWalkStart {
        PendingWalkStart(
            hikeID: UUID(),
            routeDistanceMeters: 5000,
            endsApartMeters: endsApartMeters,
            routeRevision: nil,
            distance: distance,
            at: origin
        )
    }

    /// The home on the trail: an hour of fixes wandering either side of one
    /// spot by as much as a poor indoor fix does.
    @Test("standing still never confirms, however long and however noisy")
    func standingStillNeverConfirms() {
        var pending = proposal()
        for minute in 1...60 {
            let wobble = minute.isMultiple(of: 2) ? 45.0 : -45.0
            pending.record(distance: 1000 + wobble, at: origin.addingTimeInterval(Double(minute) * 60))
        }
        #expect(!pending.isConfirmed)
    }

    @Test("moving the confirming distance along the route confirms, in either direction")
    func movingConfirms() {
        var forward = proposal()
        forward.record(distance: 1060, at: origin.addingTimeInterval(60))
        #expect(!forward.isConfirmed)
        forward.record(distance: 1000 + PendingWalkStart.confirmingMeters, at: origin.addingTimeInterval(120))
        #expect(forward.isConfirmed)

        var backward = proposal()
        backward.record(distance: 940, at: origin.addingTimeInterval(60))
        backward.record(distance: 1000 - PendingWalkStart.confirmingMeters, at: origin.addingTimeInterval(120))
        #expect(backward.isConfirmed)
    }

    /// A jump the coverage refuses to bridge is not a walk along the route:
    /// it is the hiker reappearing somewhere else on it.
    @Test("a jump past the gap bound does not confirm")
    func jumpDoesNotConfirm() {
        var pending = proposal()
        pending.record(distance: 1000 + TrailWalkPolicy.gapBoundMeters + 100, at: origin.addingTimeInterval(600))
        #expect(!pending.isConfirmed)
    }

    /// GPS re-acquiring after a tunnel, or a phone indoors snapping to
    /// another spot on the trail: one match lands a few hundred metres along,
    /// close enough for the coverage to bridge, with no walking in between.
    @Test("a single fix landing far along the route does not confirm")
    func singleFixDoesNotConfirm() {
        var pending = proposal()
        pending.record(distance: 1300, at: origin.addingTimeInterval(5))
        #expect(!pending.isConfirmed)
    }

    /// The same phone, left where it snapped: every fix after the jump lands
    /// on the one spot, which is standing still somewhere else.
    @Test("fixes stuck on one snapped spot do not confirm")
    func snappedSpotDoesNotConfirm() {
        var pending = proposal()
        for second in 1...30 {
            pending.record(distance: 1300, at: origin.addingTimeInterval(Double(second) * 5))
        }
        #expect(!pending.isConfirmed)
    }

    /// A jump that snapped back is forgotten with the setting-off it seemed
    /// to be: the walk that follows still has to go the whole way.
    @Test("a jump that snaps back does not count towards the walk that follows")
    func snappedBackJumpIsForgotten() {
        var pending = proposal()
        pending.record(distance: 1300, at: origin.addingTimeInterval(5))
        pending.record(distance: 1010, at: origin.addingTimeInterval(10))
        pending.record(distance: 1060, at: origin.addingTimeInterval(60))
        pending.record(distance: 1080, at: origin.addingTimeInterval(80))
        #expect(!pending.isConfirmed, "80 m from where the hiker set off is not yet a walk")
        pending.record(distance: 1100, at: origin.addingTimeInterval(100))
        #expect(pending.isConfirmed)
    }

    /// The walk began when the hiker set off, not when the proposal was made:
    /// an hour on the sofa before leaving is not an hour of walking.
    @Test("the confirmed walk is dated from the last fix before the hiker set off")
    func datedFromSettingOff() {
        var pending = proposal()
        let setOff = origin.addingTimeInterval(3600)
        pending.record(distance: 1020, at: origin.addingTimeInterval(1800))
        pending.record(distance: 990, at: setOff)
        pending.record(distance: 1060, at: setOff.addingTimeInterval(60))
        pending.record(distance: 1120, at: setOff.addingTimeInterval(120))

        #expect(pending.isConfirmed)
        let walk = pending.confirmedRecord
        #expect(walk.startedAt == setOff)
        #expect(walk.phaseChangedAt == setOff)
        #expect(walk.activeSeconds(at: setOff.addingTimeInterval(120)) == 120)
        #expect(walk.coverage.coveredMeters >= PendingWalkStart.confirmingMeters, "and it keeps what it covered")
    }

    @Test("a proposal expires once it has heard nothing for its window")
    func expires() {
        let pending = proposal()
        #expect(!pending.isExpired(at: origin.addingTimeInterval(PendingWalkStart.expiresAfter)))
        #expect(pending.isExpired(at: origin.addingTimeInterval(PendingWalkStart.expiresAfter + 1)))
    }

    @Test("an out-of-order fix changes nothing")
    func outOfOrderIsIgnored() {
        var pending = proposal()
        pending.record(distance: 1060, at: origin.addingTimeInterval(120))
        let before = pending
        pending.record(distance: 1200, at: origin.addingTimeInterval(60))
        #expect(pending == before)
    }

    // MARK: Where the route's ends meet

    /// A loop's trailhead is both of its ends. Set off from it the other way
    /// round from the way it is stored, and the matches land near its end:
    /// read straight along, a step of most of the route, and every step after
    /// it one nearer.
    @Test("from a loop's trailhead, setting off the other way round confirms")
    func loopTrailheadConfirmsTheOtherWayRound() {
        var fromStart = proposal(at: 0, endsApartMeters: 0)
        fromStart.record(distance: 4940, at: origin.addingTimeInterval(60))
        fromStart.record(distance: 4880, at: origin.addingTimeInterval(120))
        #expect(!fromStart.isConfirmed, "60 m covered: the step across the trailhead was not walked")
        fromStart.record(distance: 4820, at: origin.addingTimeInterval(180))
        #expect(fromStart.isConfirmed)

        var fromEnd = proposal(at: 5000, endsApartMeters: 0)
        for (step, distance) in [60.0, 120, 180].enumerated() {
            fromEnd.record(distance: distance, at: origin.addingTimeInterval(Double(step + 1) * 60))
        }
        #expect(fromEnd.isConfirmed)
    }

    /// Standing at the trailhead, fixes land either side of the join, and
    /// each of them is where the hiker stands.
    @Test("standing at a loop's trailhead never confirms, whichever end the fixes land at")
    func loopTrailheadStandingNeverConfirms() {
        var pending = proposal(at: 0, endsApartMeters: 0)
        for minute in 1...61 {
            let distance = minute.isMultiple(of: 2) ? 30.0 : 4970
            pending.record(distance: distance, at: origin.addingTimeInterval(Double(minute) * 60))
        }
        #expect(!pending.isConfirmed)
        #expect(
            pending.confirmedRecord.startedAt == origin.addingTimeInterval(61 * 60),
            "a fix past the join is not setting off"
        )
    }

    /// A loop recorded a little short of where it began: the gap between its
    /// ends is part of the way round.
    @Test("a gap between a loop's ends is crossed the way round")
    func loopGapIsCrossed() {
        var pending = proposal(at: 0, endsApartMeters: 60)
        for (step, distance) in [4980.0, 4920, 4860].enumerated() {
            pending.record(distance: distance, at: origin.addingTimeInterval(Double(step + 1) * 60))
        }
        #expect(pending.isConfirmed)
    }

    /// The far trailhead of a trail between two places is not this one.
    @Test("at one end of a trail between two places, a match at the other is not standing still")
    func farTrailheadIsElsewhere() {
        var pending = proposal(at: 0)
        pending.record(distance: 4990, at: origin.addingTimeInterval(60))
        #expect(pending.confirmedRecord.startedAt == origin)
    }

    /// A figure-eight whose trailhead is its crossing passes through it
    /// halfway too. Setting off along that pass, every step is further along
    /// the route from the start and nearer round it to the end.
    @Test("setting off along a later pass through the trailhead confirms")
    func laterPassThroughTheTrailheadConfirms() {
        var pending = PendingWalkStart(
            hikeID: UUID(),
            routeDistanceMeters: 4000,
            endsApartMeters: 0,
            routeRevision: nil,
            distance: 0,
            at: origin
        )
        for step in 0...10 {
            pending.record(distance: 2010 + Double(step) * 10, at: origin.addingTimeInterval(Double(step + 1) * 8))
        }
        #expect(pending.isConfirmed)
    }

    /// The phone indoors by a loop's trailhead, snapped a few hundred metres
    /// along and drifting back: further round the loop each time, and no
    /// nearer to being a walk.
    @Test("at a loop's trailhead, a snapped fix drifting back does not confirm")
    func loopTrailheadSnapDriftingBackDoesNotConfirm() {
        var pending = proposal(at: 0, endsApartMeters: 0)
        for (step, distance) in [300.0, 290, 280, 270].enumerated() {
            pending.record(distance: distance, at: origin.addingTimeInterval(Double(step + 1) * 5))
        }
        #expect(!pending.isConfirmed)
    }

    /// The other end of a route whose ends meet can be an out-and-back's
    /// other leg: the same ground, not the way round. A hiker found standing
    /// on the way home is matched on the way out, and their first step home
    /// lands on the leg beside it, nearly the whole route along.
    @Test("away from the trailhead, a step onto an out-and-back's other leg still confirms")
    func outAndBackOtherLegIsAlong() {
        var pending = proposal(at: 1000, endsApartMeters: 0)
        for step in 0...10 {
            pending.record(distance: 4010 + Double(step) * 10, at: origin.addingTimeInterval(Double(step + 1) * 8))
        }
        #expect(pending.isConfirmed)
    }
}
