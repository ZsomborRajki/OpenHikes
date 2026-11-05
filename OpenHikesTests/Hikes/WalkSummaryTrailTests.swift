//
//  WalkSummaryTrailTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Walk summary trail")
struct WalkSummaryTrailTests {
    private static let route = [
        RouteCoordinate(latitude: 47, longitude: 12),
        RouteCoordinate(latitude: 47.004, longitude: 12),
        RouteCoordinate(latitude: 47.012, longitude: 12.003),
    ]

    private func walk(in context: ModelContext) -> HikeWalk {
        let hike = Fixture.hike(in: context) { $0.replaceRoute(with: Self.route) }
        let length = RouteProfile(route: hike.route).totalDistanceMeters
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3600),
            activeSeconds: 3600,
            coveredIntervals: [0, length / 4],
            furthestDistanceMeters: length / 4,
            routeDistanceMeters: length,
            endReason: .ended,
            routeRevision: TrailWalkRecord.routeRevision(of: hike.route)
        )
        context.insert(walk)
        walk.hike = hike
        return walk
    }

    /// The hike's line, read as its screens read it.
    private func shownLine(of walk: HikeWalk) async throws -> ShownLine {
        let selection = ShownLineTests.selection()
        let line = ShownLine()
        line.show(try #require(walk.hike), selection: selection.lines, followedBy: selection.watch)
        await line.landing?.value
        return line
    }

    @Test("the prepared profile and revision describe the same line")
    func unchangedTrailCanBeDrawn() async throws {
        let context = try Fixture.modelContext()
        let walk = walk(in: context)
        let line = try await shownLine(of: walk)
        let key = WalkSummaryRouteKey(walk: walk, line: line)
        let trail = try await WalkSummaryTrail.prepare(along: key)

        #expect(trail.key == key)
        #expect(trail.matches(walk, on: line))
        let segments = try await trail.coveredSegments(of: walk, on: line)
        #expect(segments.count == 1)
        #expect(segments.first?.first?.latitude == Self.route.first?.latitude)
        #expect(segments.first?.last?.latitude != Self.route.last?.latitude)
    }

    @Test("a cancelled preparation cannot publish a stale trail")
    func cancelledPreparationIsRejected() async throws {
        let context = try Fixture.modelContext()
        let walk = walk(in: context)
        let key = WalkSummaryRouteKey(walk: walk, line: try await shownLine(of: walk))
        let task = Task { try await WalkSummaryTrail.prepare(along: key) }
        // Still on the main actor, before the task can enter its build.
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("an old profile stops drawing as soon as the route changes, and stops matching once the new line lands")
    func editedRouteRejectsTheOldProfile() async throws {
        let context = try Fixture.modelContext()
        let walk = walk(in: context)
        let hike = try #require(walk.hike)
        let line = try await shownLine(of: walk)
        let trail = try await WalkSummaryTrail.prepare(along: WalkSummaryRouteKey(walk: walk, line: line))
        #expect(trail.matches(walk, on: line))

        hike.replaceRoute(with: hike.route.reversed())

        await #expect(throws: CancellationError.self, "before the new line has even been read") {
            try await trail.coveredSegments(of: walk, on: line) { _, _ in
                Issue.record("an obsolete profile must not start drawing")
                return []
            }
        }
        await settleDelegateHop(until: "the new line has landed") { line.isSettled }
        #expect(!trail.matches(walk, on: line))
    }

    @Test("a route edit during drawing discards the old covered stretches")
    func editDuringDrawingIsRejected() async throws {
        let context = try Fixture.modelContext()
        let walk = walk(in: context)
        let hike = try #require(walk.hike)
        let line = try await shownLine(of: walk)
        let trail = try await WalkSummaryTrail.prepare(along: WalkSummaryRouteKey(walk: walk, line: line))
        let gate = SegmentGate()
        let task = Task {
            try await trail.coveredSegments(of: walk, on: line) { ranges, profile in
                await gate.wait()
                return await WalkHighlight.segments(covering: ranges, along: profile)
            }
        }
        await settleDelegateHop(until: "the covered-stretch calculation is in flight") { gate.started }
        hike.replaceRoute(with: hike.route.reversed())
        gate.resume()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("cancelling a drawing discards its result")
    func cancelledDrawingIsRejected() async throws {
        let context = try Fixture.modelContext()
        let walk = walk(in: context)
        let line = try await shownLine(of: walk)
        let trail = try await WalkSummaryTrail.prepare(along: WalkSummaryRouteKey(walk: walk, line: line))
        let gate = SegmentGate()
        let task = Task {
            try await trail.coveredSegments(of: walk, on: line) { ranges, profile in
                await gate.wait()
                return await WalkHighlight.segments(covering: ranges, along: profile)
            }
        }
        await settleDelegateHop(until: "the covered-stretch calculation is in flight") { gate.started }
        task.cancel()
        gate.resume()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Holds a calculation at its await so an edit or cancellation is ordered
/// before its answer, without a sleep or a race against the route's size.
@MainActor
private final class SegmentGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
