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
        store.save(
            waypoints: Self.waypoints([Line.south, Line.north]),
            places: [],
            snapsToPaths: true
        )

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
            places: [],
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
        TrailDraftStore(context: context).save(waypoints: Self.waypoints(latitudes), places: [], snapsToPaths: true)

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.map(\.latitude) == latitudes)
    }

    /// A stop's name is part of the drawing, so it comes back with the points.
    /// Without this a hiker who searched out four stops, closed the app and
    /// came back would find a route reading Start / Stop 1 / Stop 2 /
    /// Destination — the line intact and everything that made it legible gone.
    @Test("the names come back with the points they belong to")
    func namesSurvive() throws {
        let context = try context()
        var waypoints = Self.waypoints([Line.south, Line.north])
        waypoints[0].name = "Lurdy Ház"
        waypoints[1].name = "Gellért-hegy"

        TrailDraftStore(context: context).save(
            waypoints: waypoints,
            places: [],
            snapsToPaths: true
        )

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.map(\.name) == ["Lurdy Ház", "Gellért-hegy"])
    }

    /// A row written before names existed, which is every draft left behind by
    /// a build before this one — see ``TrailDraftRecord/waypointNames``, which
    /// is a second column rather than a richer point precisely so that this
    /// case is a resume rather than a migration.
    @Test("a draft written before names existed comes back unnamed")
    func namelessRowsStillResume() throws {
        let context = try context()
        let record = TrailDraftRecord(
            waypoints: Self.waypoints([Line.south, Line.north]).map(\.routeCoordinate),
            waypointNames: [],
            places: [],
            snapsToPaths: true,
            updatedAt: .now
        )
        context.insert(record)
        try context.save()

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.count == 2)
        #expect(restored.waypoints.map(\.name) == ["", ""])
    }

    /// The pairing is an invariant rather than a type, so the honest answer to
    /// a row whose two columns have come apart is the line with nothing written
    /// beside it — never a name matched to whichever point shares its index.
    @Test("names that do not pair with the points are dropped, not guessed at")
    func mismatchedNamesAreDropped() throws {
        let context = try context()
        let record = TrailDraftRecord(
            waypoints: Self.waypoints([Line.south, Line.north]).map(\.routeCoordinate),
            waypointNames: ["Lurdy Ház"],
            places: [],
            snapsToPaths: true,
            updatedAt: .now
        )
        context.insert(record)
        try context.save()

        let restored = TrailDraftStore(context: context).load()

        #expect(restored.waypoints.count == 2)
        #expect(restored.waypoints.map(\.name) == ["", ""])
    }

    @Test("saving twice rewrites the one row rather than adding another")
    func savingIsIdempotent() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)

        store.save(
            waypoints: Self.waypoints([Line.south, Line.north]),
            places: [],
            snapsToPaths: true
        )
        store.save(waypoints: Self.waypoints([Line.north]), places: [], snapsToPaths: true)

        #expect(try context.fetch(FetchDescriptor<TrailDraftRecord>()).count == 1)
        #expect(store.load().waypoints.map(\.latitude) == [Line.north])
    }

    @Test("clearing leaves no row behind")
    func clearingDeletesTheRow() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        store.save(
            waypoints: Self.waypoints([Line.south, Line.north]),
            places: [],
            snapsToPaths: true
        )

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
        store.save(waypoints: [], places: [], snapsToPaths: true)

        #expect(store.load().isEmpty)
    }
}

extension TrailDraftStoreTests {
    /// The places are written down with the points, and they are the half that
    /// keeps its identities — a place's id is what the map, the editor and the
    /// drag all name it by, and what a saved ``TrailPoint`` carries.
    @Test("the marked places survive a launch")
    func placesSurviveALaunch() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)
        let place = TrailPlace(
            latitude: Line.south,
            longitude: Line.longitude,
            name: "Hut",
            symbol: .shelter,
            note: "Locked in winter"
        )

        store.save(
            waypoints: Self.waypoints([Line.south, Line.north]),
            places: [place],
            snapsToPaths: true
        )
        let restored = TrailDraftStore(context: context).load()

        #expect(restored.places.count == 1)
        #expect(restored.places.first?.id == place.id, "a place keeps its identity")
        #expect(restored.places.first?.name == "Hut")
        #expect(restored.places.first?.symbol == .shelter)
        #expect(restored.places.first?.note == "Locked in winter")
    }

    /// A hiker who marked the hut before drawing anything has done work, and a
    /// draft that reported itself empty would have it thrown away by the next
    /// Cancel without being asked about.
    @Test("a drawing with places and no line is not nothing")
    func placesAloneAreADrawing() throws {
        let context = try context()
        let store = TrailDraftStore(context: context)

        store.save(
            waypoints: [],
            places: [TrailPlace(latitude: Line.south, longitude: Line.longitude)],
            snapsToPaths: true
        )

        #expect(!TrailDraftStore(context: context).load().isEmpty)
    }
}
