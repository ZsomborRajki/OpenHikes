//
//  TrailDraftStoreTests.swift
//  OpenHikesTests
//
//  The half-drawn trail on disk.
//
//  Two claims, and the second is the one that is easy to lose. A draft comes
//  back after the app is killed — that is what the store is *for*. And there
//  is exactly **one** of them: nothing here inserts a second row, because a
//  maker that drew one trail and found two on the next launch would have to
//  choose between them, and there is no rule that could.
//
//  Where it is kept is asserted next door in `MirroredCloudKitSchemaTests`,
//  which is what says ``TrailDraftRecord`` is not mirrored. That matters as
//  much as anything here: a draft is one device's unfinished work.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Trail draft store")
struct TrailDraftStoreTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
    }

    private static func waypoints(_ latitudes: [Double]) -> [TrailWaypoint] {
        latitudes.map { latitude in
            TrailWaypoint(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
            )
        }
    }

    private func context() throws -> ModelContext {
        try Fixture.modelContext()
    }

    @Test("nothing drawn is nothing stored")
    func emptyStoreLoadsNothing() throws {
        let store = TrailDraftStore(context: try context())
        #expect(store.load().isEmpty)
    }

    @Test("a draft comes back with its points")
    func roundTrip() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        store.save(waypoints: Self.waypoints([Line.south, Line.north]), snapsToPaths: true)

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.map(\.latitude) == [Line.south, Line.north])
    }

    /// The switch is part of the drawing rather than a global preference, so
    /// it comes back with the points — otherwise a hiker who straightened
    /// their line, closed the app and came back would find it bending again
    /// the moment they added a point.
    @Test("path-following comes back the way it was left")
    func snappingSurvives() throws {
        let context = try context()
        TrailDraftStore(context: context).save(
            waypoints: Self.waypoints([Line.south, Line.north]),
            snapsToPaths: false
        )

        #expect(!TrailDraftStore(context: context).load().snapsToPaths)
    }

    /// And a store with nothing in it answers the way a new draft starts,
    /// which is what makes ``StoredTrailDraft/nothing`` the right empty
    /// answer rather than a second kind of default.
    @Test("an empty store answers the way a new draft begins")
    func emptyStoreFollowsPaths() throws {
        #expect(TrailDraftStore(context: try context()).load().snapsToPaths)
    }

    /// The ordering is the trail. A store that came back with the points in
    /// some other order would hand a hiker a different walk.
    @Test("the points come back in the order they went down")
    func orderSurvives() throws {
        let context = try context()
        let latitudes = [Line.north, Line.south, Line.north, Line.south]
        TrailDraftStore(context: context).save(waypoints: Self.waypoints(latitudes), snapsToPaths: true)

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.map(\.latitude) == latitudes)
    }

    @Test("saving twice rewrites the one row rather than adding another")
    func savingIsIdempotent() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)

        store.save(waypoints: Self.waypoints([Line.south, Line.north]), snapsToPaths: true)
        store.save(waypoints: Self.waypoints([Line.north]), snapsToPaths: true)

        #expect(try context.fetch(FetchDescriptor<TrailDraftRecord>()).count == 1)
        #expect(store.load().waypoints.map(\.latitude) == [Line.north])
    }

    @Test("clearing leaves no row behind")
    func clearingDeletesTheRow() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        store.save(waypoints: Self.waypoints([Line.south, Line.north]), snapsToPaths: true)

        store.clear()

        #expect(store.load().isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrailDraftRecord>()).isEmpty)
    }

    @Test("clearing a store that has nothing in it is not an error")
    func clearingNothing() throws {
        let store = TrailDraftStore(context: try context())
        store.clear()
        #expect(store.load().isEmpty)
    }

    /// A row with no points and nothing at all read the same to the maker, so
    /// they answer the same. Otherwise the caller would have to know which one
    /// it got in order to do the same thing with both.
    @Test("a stored draft with no points reads as nothing drawn")
    func pointlessDraftReadsAsNothing() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        store.save(waypoints: [], snapsToPaths: true)

        #expect(store.load().isEmpty)
    }
}
