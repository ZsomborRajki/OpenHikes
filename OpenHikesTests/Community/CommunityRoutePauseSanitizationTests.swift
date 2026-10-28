//
//  CommunityRoutePauseSanitizationTests.swift
//  OpenHikesTests
//
//  A rejected coordinate must not turn a paused transfer into walked trail.
//  The boundary describes the leg arriving at its point, so losing the first
//  fix after a pause still leaves the next surviving fix in a separate piece.
//  These decode local bytes and inspect the same distance and run splitting
//  that a saved route and its map use; no transport or store is involved.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

@Suite("Community route pause sanitization")
struct CommunityRoutePauseSanitizationTests {
    private let before = [
        RouteCoordinate(latitude: 47.000, longitude: 19),
        RouteCoordinate(latitude: 47.001, longitude: 19),
    ]
    private let after = [
        RouteCoordinate(latitude: 47.050, longitude: 19),
        RouteCoordinate(latitude: 47.051, longitude: 19),
    ]

    private func decoded(_ route: [RouteCoordinate]) throws -> [RouteCoordinate] {
        CommunityRoutePayload.route(from: try JSONEncoder().encode(CommunityRouteDocument(route: route)))
    }

    private func rejected(_ count: Int, paused: Bool) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(
                latitude: 90 + Double(index),
                longitude: 19,
                boundary: paused && index == 0 ? .paused : nil
            )
        }
    }

    @Test("a rejected resume keeps the transfer out of distance and solid trail", arguments: [1, 3])
    func rejectedResumeKeepsThePause(rejectedCount: Int) throws {
        let read = try decoded(before + rejected(rejectedCount, paused: true) + after)

        var expected = before + after
        expected[2].boundary = .paused
        #expect(read == expected)
        #expect(read.lengthMeters.isApproximatelyEqual(
            to: before.lengthMeters + after.lengthMeters, absoluteTolerance: 0.001
        ))
        #expect(read.trailRuns.pausedLegs == [1])
        #expect(read.trailRuns.walkedRuns == [0..<2, 2..<4])
        #expect(read.trailRuns.pausedStretches == [1..<3])
    }

    @Test("several rejected pauses still separate the surviving walked pieces")
    func consecutiveRejectedPausesKeepThePause() throws {
        let read = try decoded(before + rejected(1, paused: true) + rejected(1, paused: true) + after)

        #expect(read.filter(\.isPauseBoundary).count == 1)
        #expect(read.trailRuns.walkedRuns == [0..<2, 2..<4])
        #expect(read.lengthMeters.isApproximatelyEqual(
            to: before.lengthMeters + after.lengthMeters, absoluteTolerance: 0.001
        ))
    }

    @Test("a pause on rejected leading points does not cut the first walked leg", arguments: [false, true])
    func rejectedLeadingPointsLeaveOneWalk(paused: Bool) throws {
        let read = try decoded(rejected(2, paused: paused) + before)

        var expected = before
        if paused { expected[0].boundary = .paused }
        #expect(read == expected)
        #expect(read.trailRuns.pausedLegs.isEmpty)
        #expect(read.trailRuns.walkedRuns == [0..<2])
        #expect(read.lengthMeters.isApproximatelyEqual(to: before.lengthMeters, absoluteTolerance: 0.001))
    }

    @Test("a rejected trailing pause never moves onto the preceding walk", arguments: [1, 3])
    func rejectedTrailingPointsLeaveTheWalkUnchanged(rejectedCount: Int) throws {
        let read = try decoded(before + rejected(rejectedCount, paused: true))

        #expect(read == before)
        #expect(read.trailRuns.pausedLegs.isEmpty)
        #expect(read.trailRuns.walkedRuns == [0..<2])
        #expect(read.lengthMeters.isApproximatelyEqual(to: before.lengthMeters, absoluteTolerance: 0.001))
    }

    @Test("an ordinary rejected point keeps the neighbors connected as walked trail")
    func rejectedWalkedPointDoesNotCreateAPause() throws {
        let published = before + rejected(1, paused: false) + after
        let expected = before + after

        let read = try decoded(published)

        #expect(read == expected)
        #expect(read.trailRuns.pausedLegs.isEmpty)
        #expect(read.trailRuns.walkedRuns == [0..<4])
        #expect(read.lengthMeters.isApproximatelyEqual(to: expected.lengthMeters, absoluteTolerance: 0.001))
    }
}
