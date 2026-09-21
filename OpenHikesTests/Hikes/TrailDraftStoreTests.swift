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
        store.save(waypoints: Self.waypoints([Line.south, Line.north]))

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.map(\.latitude) == [Line.south, Line.north])
    }

    /// The ordering is the trail. A store that came back with the points in
    /// some other order would hand a hiker a different walk.
    @Test("the points come back in the order they went down")
    func orderSurvives() throws {
        let context = try context()
        let latitudes = [Line.north, Line.south, Line.north, Line.south]
        TrailDraftStore(context: context).save(waypoints: Self.waypoints(latitudes))

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.map(\.latitude) == latitudes)
    }

    @Test("saving twice rewrites the one row rather than adding another")
    func savingIsIdempotent() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)

        store.save(waypoints: Self.waypoints([Line.south, Line.north]))
        store.save(waypoints: Self.waypoints([Line.north]))

        #expect(try context.fetch(FetchDescriptor<TrailDraftRecord>()).count == 1)
        #expect(store.load().map(\.latitude) == [Line.north])
    }

    @Test("clearing leaves no row behind")
    func clearingDeletesTheRow() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        store.save(waypoints: Self.waypoints([Line.south, Line.north]))

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
        store.save(waypoints: [])

        #expect(store.load().isEmpty)
    }
}
