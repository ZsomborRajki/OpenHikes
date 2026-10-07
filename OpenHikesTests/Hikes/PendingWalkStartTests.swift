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

    private func proposal(at distance: Double = 1000) -> PendingWalkStart {
        PendingWalkStart(
            hikeID: UUID(),
            routeDistanceMeters: 5000,
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
}
