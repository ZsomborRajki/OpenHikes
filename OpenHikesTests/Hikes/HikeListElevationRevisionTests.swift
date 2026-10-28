//
//  HikeListElevationRevisionTests.swift
//  OpenHikesTests
//
//  An incoming route edit does not execute the editor on this device. Its
//  local climb cache must describe the received route, including new heights
//  and pause boundaries, even after both stores have been reopened.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@Suite("Library elevation follows the received route")
struct HikeListElevationRevisionTests {
    enum Edit: CaseIterable {
        case heights
        case pause
        case noHeights

        var route: [RouteCoordinate] {
            var points = HikeListElevationRevisionTests.originalRoute
            switch self {
            case .heights:
                points[1].elevation = 350
                points[2].elevation = 600
            case .pause:
                points[2].boundary = .paused
            case .noHeights:
                for index in points.indices { points[index].elevation = nil }
            }
            return points
        }

        var climb: Double? {
            switch self {
            case .heights: 500
            case .pause: 50
            case .noHeights: nil
            }
        }
    }

    private static let originalRoute = [
        RouteCoordinate(latitude: 47, longitude: 19, elevation: 100),
        RouteCoordinate(latitude: 47.001, longitude: 19, elevation: 150),
        RouteCoordinate(latitude: 47.002, longitude: 19, elevation: 200),
    ]

    @Test("an independent route update replaces its old cached relief after reopen", arguments: Edit.allCases)
    func incomingRouteEditInvalidatesTheCache(edit: Edit) async throws {
        let sandbox = try StoreSandbox()
        let id = try await sandbox.withStore { context in
            let hike = Fixture.hike(in: context, title: "Received trail", route: Self.originalRoute)
            try context.save()
            #expect(await HikeListMetrics.fillElevation(for: [hike.id], in: context.container))
            let measured = try #require(try Self.hike(hike.id, in: ModelContext(context.container)))
            try Self.expectClimb(100, on: measured)
            return hike.id
        }

        // A different writer replaces the mirrored line. Its local sidecar
        // is left untouched, matching the state on a receiving device.
        try sandbox.withStore { context in
            let hike = try #require(try Self.hike(id, in: context))
            hike.replaceRoute(with: edit.route)
            try context.save()
        }

        try await sandbox.withStore { context in
            let received = try #require(try Self.hike(id, in: context))
            #expect(received.route == edit.route)
            let candidates = HikeListOrder.hikesForElevationValidation(in: [received], for: .hilliest)
            #expect(candidates == [id], "a non-nil figure is not evidence it measures this route")
            #expect(await HikeListMetrics.fillElevation(for: candidates, in: context.container))
            let fresh = try #require(try Self.hike(id, in: ModelContext(context.container)))
            try Self.expectClimb(edit.climb, on: fresh)
        }

        try sandbox.withStore { context in
            let reopened = try #require(try Self.hike(id, in: context))
            try Self.expectClimb(edit.climb, on: reopened)
        }
    }

    @Test("the same visible hike receives new relief without changing the sort or count")
    func visibleRouteChangesRefreshTheCache() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        try context.save()
        var publications = 0
        let observing = Task {
            await HikeListMetrics.observeElevation(in: [hike], container: container) {
                publications += 1
            }
        }
        defer { observing.cancel() }
        await settleDelegateHop(until: "the visible trail's original relief to be published") {
            publications == 1
        }
        try Self.expectClimb(100, on: hike)

        // The receiving context now exposes the changed route on the same
        // row. Neither its identity, list count nor selected sort changes.
        hike.replaceRoute(with: Edit.heights.route)
        try context.save()
        await settleDelegateHop(until: "the same visible trail's new heights to be measured") {
            publications == 2
        }
        try Self.expectClimb(Edit.heights.climb, on: hike)

        hike.replaceRoute(with: Edit.noHeights.route)
        try context.save()
        await settleDelegateHop(until: "the visible trail's obsolete relief to be cleared") {
            publications == 3
        }
        try Self.expectClimb(nil, on: hike)
        observing.cancel()
        await observing.value
        #expect(try ModelContext(container).fetch(FetchDescriptor<HikeLocalState>()).count == 1)
    }

    @Test("matching durable elevation figures are reused after reopen")
    func aMatchingCacheIsNotWrittenAgain() async throws {
        let sandbox = try StoreSandbox()
        let id = try await sandbox.withStore { context in
            let hike = Fixture.hike(in: context, route: Self.originalRoute)
            try context.save()
            #expect(await HikeListMetrics.fillElevation(for: [hike.id], in: context.container))
            return hike.id
        }
        try await sandbox.withStore { context in
            #expect(await HikeListMetrics.fillElevation(for: [id], in: context.container) == false)
            let hike = try #require(try Self.hike(id, in: context))
            try Self.expectClimb(100, on: hike)
        }
    }

    @Test("a refused refresh leaves the old identity eligible for a later successful retry")
    func refusedRefreshRestoresItsIdentity() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        try context.save()
        #expect(await HikeListMetrics.fillElevation(for: [hike.id], in: container))
        hike.replaceRoute(with: Edit.heights.route)
        try context.save()
        let measured = await HikeListMetrics.measureElevation(for: [hike.id], in: container)
        #expect(measured.count == 1)

        #expect(HikeListMetrics.cacheElevation(measured, in: container) { _ in
            throw CocoaError(.fileWriteUnknown)
        } == false)
        try Self.expectClimb(100, on: hike)
        try context.save()

        // Leaving the new fingerprint beside the restored old figures would
        // incorrectly suppress this retry and keep the old climb forever.
        #expect(await HikeListMetrics.fillElevation(for: [hike.id], in: container))
        try Self.expectClimb(Edit.heights.climb, on: hike)
    }

    private static func hike(_ id: UUID, in context: ModelContext) throws -> Hike? {
        try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
    }

    private static func expectClimb(_ expected: Double?, on hike: Hike) throws {
        if let expected {
            let actual = try #require(hike.climbMeters)
            #expect(actual.isApproximatelyEqual(to: expected, absoluteTolerance: 0.001))
        } else {
            #expect(hike.climbMeters == nil)
            #expect(hike.descentMeters == nil)
        }
    }
}
