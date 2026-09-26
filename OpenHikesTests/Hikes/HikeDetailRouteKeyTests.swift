//
//  HikeDetailRouteKeyTests.swift
//  OpenHikesTests
//
//  What restarts the hike detail screen's route-derived work.
//
//  *Edit Route* keeps the hike's id and replaces its line, and mirroring can
//  deliver that edit to a screen that is already open. The screen's profile,
//  statistics and follow loop are keyed on ``HikeDetailRouteKey``, so what is
//  asserted here is that the key moves with the line — and only with the
//  line, since every restart also resets the tracker and re-enters the loop.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike detail route key")
struct HikeDetailRouteKeyTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
        static let further: Double = 47.6400
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    private func savedTrail(in context: ModelContext) throws -> Hike {
        try #require(
            TrailDraftSave.hike(from: Self.draft([Line.south, Line.north]), named: "Ridge", into: context).hike
        )
    }

    @Test("an edited line under the same id is a new key")
    func anEditChangesTheKey() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let before = HikeDetailRouteKey(hike)

        let edited = Self.draft([Line.south, Line.north, Line.further])
        try #require(TrailDraftSave.update(hike, from: edited, openedWith: [], into: context).hike != nil)

        let after = HikeDetailRouteKey(hike)
        #expect(after.hikeID == before.hikeID, "the edit keeps the hike")
        #expect(after != before, "so the id alone could not have said the line had changed")
    }

    /// The restart is only worth anything if what it builds follows the new
    /// line: a fix at the far end of the extension is off the old route by
    /// hundreds of metres and on the new one.
    @Test("the line an edit leaves prepares into a matcher for that line")
    func theNewKeyMatchesOnTheNewLine() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let before = HikeDetailRouteKey(hike)
        let edited = Self.draft([Line.south, Line.north, Line.further])
        try #require(TrailDraftSave.update(hike, from: edited, openedWith: [], into: context).hike != nil)
        let after = HikeDetailRouteKey(hike)

        let old = try await HikeDetailPreparation.prepare(route: before.route, distanceMeters: before.distanceMeters)
        let new = try await HikeDetailPreparation.prepare(route: after.route, distanceMeters: after.distanceMeters)
        let fix = Self.coordinate(Line.further)

        let oldMatch = try #require(old.profile.nearestPoint(to: fix))
        let newMatch = try #require(new.profile.nearestPoint(to: fix))
        #expect(oldMatch.offRouteMeters > RouteProfile.followMatchThresholdMeters)
        #expect(newMatch.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
        #expect(new.stats.first { $0.label == "Distance" }?.value != old.stats.first { $0.label == "Distance" }?.value)
    }

    /// Every restart puts the tracker back at the start and re-enters the
    /// follow loop, so a change that leaves the line alone must not cause one.
    @Test("changes that leave the line alone keep the key")
    func otherChangesKeepTheKey() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let before = HikeDetailRouteKey(hike)

        hike.customName = "Renamed"
        hike.tintHex = "#FF0000"
        hike.autoFollowEnabled.toggle()
        hike.surfaceMetersByCategory = ["paved": 400]
        try context.save()

        #expect(HikeDetailRouteKey(hike) == before)
    }
}
