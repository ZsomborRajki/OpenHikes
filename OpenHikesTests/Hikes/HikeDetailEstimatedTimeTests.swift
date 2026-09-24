//
//  HikeDetailEstimatedTimeTests.swift
//  OpenHikesTests
//
//  The *Estimated Time* a route with no clock shows in place of a duration —
//  and, as much, where it does not: a measured duration always wins, and a
//  route with no heights has nothing to estimate the climb from.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

@Suite("Hike detail estimated time")
struct HikeDetailEstimatedTimeTests {
    private static let start = Date(timeIntervalSince1970: 1_757_000_000)
    private static let distanceMeters = 8000.0

    /// Up 1,000 m and down 200 m over the line, far past the deadband.
    private static func route(clocked: Bool, heights: Bool = true) -> [RouteCoordinate] {
        let elevations: [Double] = [800, 1300, 1800, 1600]
        return elevations.enumerated().map { index, elevation in
            RouteCoordinate(
                latitude: 47.60 + Double(index) * 0.02,
                longitude: 12.90,
                elevation: heights ? elevation : nil,
                timestamp: clocked ? start.addingTimeInterval(Double(index) * 3600) : nil
            )
        }
    }

    private func stats(for route: [RouteCoordinate]) async throws -> [String: String] {
        let prepared = try await HikeDetailPreparation.prepare(route: route, distanceMeters: Self.distanceMeters)
        return Dictionary(prepared.stats.map { ($0.label, $0.value) }) { first, _ in first }
    }

    @Test("a clockless route with heights shows an estimate, as a headline")
    func aClocklessRouteIsEstimated() async throws {
        let prepared = try await HikeDetailPreparation.prepare(
            route: Self.route(clocked: false),
            distanceMeters: Self.distanceMeters
        )
        let estimate = try #require(prepared.stats.first { $0.label == "Estimated Time" })
        let expected = WalkingTimeEstimate.seconds(
            distanceMeters: Self.distanceMeters,
            ascentMeters: 1000,
            descentMeters: 200
        )

        #expect(estimate.value == HikeFormat.travelTime(expected))
        #expect(estimate.isHeadline)
        #expect(!prepared.stats.contains { $0.label == "Duration" })
    }

    /// A measurement and an estimate are never drawn together.
    @Test("a recorded route shows its duration and no estimate")
    func aMeasuredDurationWins() async throws {
        let stats = try await stats(for: Self.route(clocked: true))
        #expect(stats["Duration"] != nil)
        #expect(stats["Estimated Time"] == nil)
    }

    /// A flat figure on an alpine route is the error this stat corrects, so
    /// with nothing to count the climb from there is no figure.
    @Test("a clockless route with no heights shows no time at all")
    func noHeightsMeansNoEstimate() async throws {
        let stats = try await stats(for: Self.route(clocked: false, heights: false))
        #expect(stats["Duration"] == nil)
        #expect(stats["Estimated Time"] == nil)
    }
}
