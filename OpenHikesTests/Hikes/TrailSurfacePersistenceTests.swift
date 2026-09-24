//
//  TrailSurfacePersistenceTests.swift
//  OpenHikesTests
//
//  "Trail surface persistence", split out of TrailSurfaceTests.swift so that
//  a file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail surface persistence")
struct TrailSurfacePersistenceTests {
    @Test("a breakdown round-trips through the hike that stores it")
    func roundTripsThroughAHike() throws {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        #expect(hike.surfaceBreakdown == nil)

        hike.surfaceBreakdown = TrailSurfaceBreakdown(
            metersByCategory: [.gravel: 700, .paved: 200, .unmapped: 100]
        )

        #expect(hike.surfaceMetersByCategory["gravel"] == 700)
        let restored = try #require(hike.surfaceBreakdown)
        #expect(restored.shares.map(\.category) == [.gravel, .paved, .unmapped])
        #expect(restored.totalMeters == 1000)
    }

    @Test("clearing the breakdown clears the stored categories")
    func clearingRemovesStoredCategories() {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceBreakdown = TrailSurfaceBreakdown(
            metersByCategory: [.gravel: 700]
        )

        hike.surfaceBreakdown = nil

        #expect(hike.surfaceMetersByCategory.isEmpty)
    }

    @Test("a category this build doesn't know is dropped, not refused")
    func ignoresUnrecognizedStoredCategories() throws {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceMetersByCategory = ["gravel": 300, "lunar_regolith": 100]

        let restored = try #require(hike.surfaceBreakdown)
        #expect(restored.shares.map(\.category) == [.gravel])
        // Renormalised over what survived, so the percentages still add up.
        #expect(restored.totalMeters == 300)
    }

    @Test("a store with nothing recognisable reads as never analyzed")
    func unrecognizedOnlyReadsAsNil() {
        let hike = Hike(title: "Thumsee", distanceMeters: 1000)
        hike.surfaceMetersByCategory = ["lunar_regolith": 100]

        #expect(hike.surfaceBreakdown == nil)
    }
}
