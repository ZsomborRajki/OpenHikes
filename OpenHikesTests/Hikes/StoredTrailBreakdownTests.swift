//
//  StoredTrailBreakdownTests.swift
//  OpenHikesTests
//
//  When opening a hike measures its surface and difficulty: while either
//  breakdown reads as never analyzed, and not again once both are stored.
//
//  The second half is a decision rather than an accident (#1036). A breakdown
//  an older analyzer measured keeps its figures after an upgrade, because
//  AGENTS.md *Schema and migration policy* treats existing data as resettable
//  and converts none of it. So a change that starts measuring stored hikes
//  again fails here, and has to say why.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Stored trail breakdowns")
struct StoredTrailBreakdownTests {
    /// #1010's route: 111 m walked, 1.1 km crossed with the recording paused,
    /// and 111 m walked.
    private static let pausedTransfer = [
        RouteCoordinate(latitude: 47.000, longitude: 12),
        RouteCoordinate(latitude: 47.001, longitude: 12),
        RouteCoordinate(latitude: 47.011, longitude: 12, boundary: .paused),
        RouteCoordinate(latitude: 47.012, longitude: 12),
    ]

    /// What a build before #1010 stored for that route, the transfer measured
    /// as trail: 1,334 m, most of it unmapped, against the hike's 222 m. Today's
    /// analyzer gives the same figures for that line with its pause taken out.
    /// #1010's graph tags both walks gravel and grades neither, so difficulty
    /// found them `unknown`.
    @Test("a breakdown an older analyzer stored is kept, not measured again")
    func anOlderAnalyzersBreakdownIsKept() throws {
        let container = try Fixture.modelContainer()
        let olderBuild = ModelContext(container)
        _ = Fixture.hike(in: olderBuild, route: Self.pausedTransfer) { hike in
            hike.surfaceMetersByCategory = ["gravel": 262, "unmapped": 1072]
            hike.difficultyMetersByGrade = ["unknown": 262, "unmapped": 1072]
        }
        try olderBuild.save()

        // Opened from the store, as the first open after the upgrade is.
        let hike = try #require(try ModelContext(container).fetch(FetchDescriptor<Hike>()).first)
        let surface = try #require(hike.surfaceBreakdown)
        let difficulty = try #require(hike.difficultyBreakdown)
        #expect(
            surface.meters(for: .unmapped) > hike.distanceMeters,
            "the stored figures still count the transfer, which the hike's distance leaves out"
        )
        #expect(difficulty.meters(for: .unmapped) > hike.distanceMeters)

        #expect(!hike.needsTrailBreakdowns)
    }

    /// The rule's other half. A surface column holding only a category this
    /// build doesn't recognize reads as never analyzed, even beside a
    /// difficulty breakdown it can read, so opening that hike measures both.
    @Test("a hike is measured while either breakdown reads as never analyzed")
    func eitherBreakdownUnreadIsMeasured() throws {
        let context = try Fixture.modelContext()
        let neverOpened = Fixture.hike(in: context, route: Self.pausedTransfer)
        let surfaceOnly = Fixture.hike(in: context, route: Self.pausedTransfer) { hike in
            hike.surfaceMetersByCategory = ["gravel": 222]
        }
        let unrecognizedSurface = Fixture.hike(in: context, route: Self.pausedTransfer) { hike in
            hike.surfaceMetersByCategory = ["lunar_regolith": 222]
            hike.difficultyMetersByGrade = ["unknown": 222]
        }
        try #require(unrecognizedSurface.difficultyBreakdown != nil)

        #expect(neverOpened.needsTrailBreakdowns)
        #expect(surfaceOnly.needsTrailBreakdowns)
        #expect(unrecognizedSurface.needsTrailBreakdowns)
    }
}
