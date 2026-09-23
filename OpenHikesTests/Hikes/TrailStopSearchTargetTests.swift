//
//  TrailStopSearchTargetTests.swift
//  OpenHikesTests
//
//  Which picks frame the whole line and which go to the place.
//
//  Picking the destination used to zoom to its pin, with the route it had just
//  drawn mostly off the screen. The rule that replaced it is by the row: a
//  pick that lands on an end frames the line, and a stop in the middle is
//  still where the camera goes. *Add Stop* is the case worth pinning, because
//  its row says "stop" and what it puts down is an end.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail stop search target")
struct TrailStopSearchTargetTests {
    @Test("The start and the destination land on an end", arguments: [
        TrailStopSearchTarget.open(.start),
        .open(.end),
        .existing(id: UUID(), role: .start),
        .existing(id: UUID(), role: .end),
    ])
    func endsLandOnAnEnd(_ target: TrailStopSearchTarget) {
        #expect(target.landsOnAnEnd)
    }

    @Test("Add Stop lands on an end, because it fills an open field or appends a destination")
    func addStopLandsOnAnEnd() {
        #expect(TrailStopSearchTarget.newStop.landsOnAnEnd)
    }

    @Test("A stop in the middle of the line does not land on an end")
    func middleStopDoesNot() {
        #expect(!TrailStopSearchTarget.existing(id: UUID(), role: .stop(number: 1)).landsOnAnEnd)
    }
}
