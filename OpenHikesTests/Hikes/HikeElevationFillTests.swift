//
//  HikeElevationFillTests.swift
//  OpenHikesTests
//
//  A library hike with no heights, given a subscriber's heights once and
//  keeping them — see `HikeElevationFill.swift`. The source is a stub: the
//  real one is billed, and refuses anybody without the subscription before
//  it forms a request, which `CuratedElevationTests` covers.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

@MainActor
@Suite("Hike elevation fill")
struct HikeElevationFillTests {
    /// Heights rising a metre per point asked about, counting every request.
    nonisolated private final class RisingSource: CuratedElevationSourcing, @unchecked Sendable {
        private let asked = Mutex(0)
        private let gate: TestGate?
        var requests: Int { asked.withLock { $0 } }

        init(gate: TestGate? = nil) {
            self.gate = gate
        }

        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
            asked.withLock { $0 += 1 }
            await gate?.wait()
            return coordinates.indices.map { 500 + Double($0) }
        }
    }

    /// A source that cannot answer — a refusal, a timeout, no key.
    nonisolated private struct RefusingSource: CuratedElevationSourcing {
        @concurrent
        func heights(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double] {
            throw CuratedElevationFailure.notEntitled
        }
    }

    /// A line of `count` points heading north, with `elevation` on each.
    private static func route(count: Int, elevation: Double? = nil) -> [RouteCoordinate] {
        (0..<count).map { index in
            RouteCoordinate(latitude: 47.6 + Double(index) * 0.0005, longitude: 12.86, elevation: elevation)
        }
    }

    private static func library(route: [RouteCoordinate]) throws -> (ModelContext, Hike) {
        let context = ModelContext(try ModelContainer.openHikes(isStoredInMemoryOnly: true))
        let hike = Hike(title: "Imported", distanceMeters: 1000)
        hike.replaceRoute(with: route)
        context.insert(hike)
        try context.save()
        return (context, hike)
    }

    /// More points than are asked about, so the ones in between have to be
    /// interpolated for *Elevation* to colour the line.
    @Test("a hike with no heights gets one on every point, and keeps them")
    func fillsEveryPoint() async throws {
        let (context, hike) = try Self.library(route: Self.route(count: 500))
        let source = RisingSource()

        let filled = await HikeElevationFill.fill(hike, from: source, in: context)

        #expect(filled)
        #expect(hike.route.allSatisfy { $0.elevation?.isFinite == true })
        #expect(!context.hasChanges, "the heights are saved, not left pending")
        #expect(!HikeElevationFill.canFill(hike))
        #expect(await HikeElevationFill.fill(hike, from: source, in: context) == false)
        #expect(source.requests == 1, "a hike that has heights is never asked about again")
    }

    @Test("a hike with any height of its own is left as it is, and nothing is asked")
    func leavesMeasuredHikesAlone() async throws {
        var route = Self.route(count: 10)
        route[4].elevation = 812
        let (context, hike) = try Self.library(route: route)
        let source = RisingSource()

        #expect(await HikeElevationFill.fill(hike, from: source, in: context) == false)
        #expect(hike.route == route)
        #expect(source.requests == 0)
    }

    @Test("a walk still being recorded is not asked about")
    func skipsARecording() async throws {
        let (context, hike) = try Self.library(route: Self.route(count: 10))
        hike.isRecording = true
        let source = RisingSource()

        #expect(await HikeElevationFill.fill(hike, from: source, in: context) == false)
        #expect(source.requests == 0)
    }

    @Test("a source that cannot answer leaves the hike without heights")
    func refusalChangesNothing() async throws {
        let route = Self.route(count: 10)
        let (context, hike) = try Self.library(route: route)

        #expect(await HikeElevationFill.fill(hike, from: RefusingSource(), in: context) == false)
        #expect(hike.route == route)
    }

    @Test("a refused save puts the line back without heights")
    func refusedSaveRollsBack() async throws {
        struct Refused: Error {}
        let route = Self.route(count: 10)
        let (context, hike) = try Self.library(route: route)

        let filled = await HikeElevationFill.fill(hike, from: RisingSource(), in: context) { _ in throw Refused() }

        #expect(!filled)
        #expect(hike.route == route)
    }

    @Test("a refused elevation save preserves edits made while the request was in flight")
    func refusedSavePreservesUnrelatedChanges() async throws {
        let route = Self.route(count: 10)
        let (context, hike) = try Self.library(route: route)
        let unrelated = Fixture.hike(in: context, title: "Other hike", route: route)
        try context.save()
        let gate = TestGate()
        defer { gate.open() }
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])
        let filling = Task {
            await HikeElevationFill.fill(hike, from: RisingSource(gate: gate), in: context, save: saver.save)
        }
        await settleDelegateHop(until: "the elevation request to be in flight") { gate.isHolding }

        unrelated.title = "Renamed while reading heights"
        let inserted = Fixture.hike(in: context, title: "Added while reading heights", route: route)
        let insertedID = inserted.id
        hike.title = "Renamed target"
        gate.open()

        #expect(await filling.value == false)
        #expect(hike.route == route)
        #expect(hike.title == "Renamed target")
        #expect(unrelated.title == "Renamed while reading heights")
        #expect(inserted.modelContext === context)

        // A later autosave must keep the hiker's work without accidentally
        // committing the elevation change whose save was refused.
        try context.save()
        let stored = try ModelContext(context.container).fetch(FetchDescriptor<Hike>())
        #expect(stored.count == 3)
        #expect(stored.first { $0.id == unrelated.id }?.title == "Renamed while reading heights")
        #expect(stored.first { $0.id == insertedID }?.title == "Added while reading heights")
        let restored = try #require(stored.first { $0.id == hike.id })
        #expect(restored.title == "Renamed target")
        #expect(restored.route == route)
    }
}
