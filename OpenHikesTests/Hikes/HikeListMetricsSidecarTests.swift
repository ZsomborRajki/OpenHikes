//
//  HikeListMetricsSidecarTests.swift
//  OpenHikesTests
//
//  A library sweep must enrich the sidecar that already owns a hike's tiles,
//  including a row the UI has inserted but not saved yet. Two rows joined by
//  the same hikeID let a later lookup hide real offline coverage.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@Suite("Library elevation keeps one complete sidecar")
struct HikeListMetricsSidecarTests {
    @Test("a pending first tile claim and an elevation sweep share one durable row")
    func pendingFirstClaimSurvivesElevationFill() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let hike = Fixture.hike(in: context)
        try context.save()

        hike.autoSavedTileKeys = ["osm/1/0/0"]
        hike.autoSaveTilesEnabled = false
        hike.listOrder = 3
        #expect(hike.localState?.modelContext === context)

        #expect(await HikeListMetrics.fillElevation(for: [hike.id], in: container))
        try context.save()

        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<HikeLocalState>())
        #expect(rows.count == 1)
        let state = try #require(rows.first)
        #expect(state.hikeID == hike.id)
        #expect(state.autoSavedTileKeys == ["osm/1/0/0"])
        #expect(!state.autoSaveTilesEnabled)
        #expect(state.listOrder == 3)
        let climb = try #require(state.climbMeters)
        let descent = try #require(state.descentMeters)
        let expectedClimb = try #require(hike.routeStatistics.elevationGain?.value)
        let expectedDescent = try #require(hike.routeStatistics.elevationLoss?.value)
        #expect(climb.isApproximatelyEqual(to: expectedClimb, absoluteTolerance: 1e-6))
        #expect(descent.isApproximatelyEqual(to: expectedDescent, absoluteTolerance: 1e-6))
    }

    @Test("a failed publication preserves pending claims and unrelated edits")
    func failedSaveRestoresOnlyElevationFields() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let hike = Fixture.hike(in: context)
        try context.save()
        let measured = await HikeListMetrics.measureElevation(for: [hike.id], in: container)
        hike.autoSavedTileKeys = ["osm/1/0/0"]
        hike.customName = "Keep this edit"
        let other = Fixture.hike(in: context, title: "Keep this insertion")

        let saved = HikeListMetrics.cacheElevation(measured, in: container) { _ in
            throw RefusedSave.refused
        }
        #expect(!saved)
        #expect(hike.climbMeters == nil)
        #expect(hike.descentMeters == nil)
        try context.save()

        let reader = ModelContext(container)
        let rows = try reader.fetch(FetchDescriptor<HikeLocalState>())
        #expect(rows.count == 1)
        #expect(rows.first?.autoSavedTileKeys == ["osm/1/0/0"])
        let hikes = try reader.fetch(FetchDescriptor<Hike>())
        #expect(hikes.first { $0.id == hike.id }?.customName == "Keep this edit")
        #expect(hikes.contains { $0.id == other.id })
    }

    private enum RefusedSave: Error {
        case refused
    }
}
