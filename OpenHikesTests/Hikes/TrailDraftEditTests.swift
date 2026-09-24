//
//  TrailDraftEditTests.swift
//  OpenHikesTests
//
//  *Edit Route*: a trail drawn in the maker can be reopened on the stops it
//  was drawn from, and saving writes back into the same hike.
//
//  What is defended is what "the same hike" means. Walks, places, photographs,
//  a widget pin and a publication all point at the row by its id, so an edit
//  that made a new row — or lost the one it had — would quietly orphan all of
//  them.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Trail draft edit")
struct TrailDraftEditTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let middle: Double = 47.6320
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

    /// A trail saved from the maker, the way the Save button saves one.
    private func savedTrail(in context: ModelContext, _ latitudes: [Double] = [Line.south, Line.north]) throws -> Hike {
        try #require(TrailDraftSave.hike(from: Self.draft(latitudes), named: "Ridge", into: context).hike)
    }

    // MARK: What a save keeps

    @Test("a drawn trail keeps the stops it was drawn from")
    func aSaveKeepsItsStops() throws {
        let context = try Fixture.modelContext()
        let draft = Self.draft([Line.south, Line.north])
        draft.setTravelMode(.walking)
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike)

        let drawn = try #require(hike.drawnRoute)
        #expect(drawn.waypoints.map(\.latitude) == [Line.south, Line.north])
        #expect(drawn.travelMode == .walking)
        #expect(drawn.editedUnderSubmissionID == nil)
    }

    @Test("a recording or an import carries no stops, so no Edit Route")
    func otherHikesHaveNoStops() throws {
        let context = try Fixture.modelContext()
        #expect(Fixture.hike(in: context, title: "Imported").drawnRoute == nil)
    }

    // MARK: Writing back

    @Test("saving an edit writes into the same hike, and keeps its walks and name")
    func anEditIsTheSameHike() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let id = hike.id
        let walk = HikeWalk(
            hikeID: id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 600,
            coveredIntervals: [0, 300],
            furthestDistanceMeters: 300,
            routeDistanceMeters: hike.distanceMeters,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = hike
        hike.surfaceMetersByCategory = ["paved": 400]
        let lengthBefore = hike.distanceMeters

        let edited = Self.draft([Line.south, Line.north, Line.further])
        let outcome = TrailDraftSave.update(hike, from: edited, openedWith: [], into: context)

        let saved = try #require(outcome.hike)
        #expect(saved.id == id)
        #expect(saved.title == "Ridge")
        #expect(saved.distanceMeters > lengthBefore)
        #expect(saved.route.count == 3)
        #expect(saved.drawnRoute?.waypoints.count == 3)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1, "no second trail")
        #expect(saved.walks?.count == 1, "the walk along the old line is history, and kept")
        #expect(saved.surfaceMetersByCategory.isEmpty, "the old line's breakdown is asked for again")
    }

    /// A place the edit took away takes nothing with it but itself.
    @Test("a place the edit drops returns its photographs to the gallery")
    func droppedPlacesUnfileTheirPhotos() throws {
        let context = try Fixture.modelContext()
        let draft = Self.draft([Line.south, Line.north])
        let spring = TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring")
        draft.addPlaces([spring])
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike)
        var photo = HikePhoto()
        photo.placeID = spring.id
        hike.addPhoto(photo)

        // Redrawn along a line the spring is nowhere near, and without it.
        let away = TrailDraft()
        away.append(CLLocationCoordinate2D(latitude: Line.south, longitude: Line.longitude + 0.02))
        away.append(CLLocationCoordinate2D(latitude: Line.north, longitude: Line.longitude + 0.02))
        let saved = try #require(TrailDraftSave.update(hike, from: away, openedWith: [spring.id], into: context).hike)

        #expect(saved.places.isEmpty)
        #expect(saved.photos.count == 1)
        #expect(saved.photos.first?.placeID == nil)
    }

    /// Share Again is gone, so an edit changes the hike and not the listing —
    /// and the hike says so. A fresh share is a new submission, and the note
    /// goes by itself.
    @Test("what happened to the hike's places while the edit was open is kept")
    func placesChangedDuringTheEditSurvive() throws {
        let context = try Fixture.modelContext()
        let draft = Self.draft([Line.south, Line.north])
        let hut = TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Hut")
        draft.addPlaces([hut])
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike)
        let row = try #require(hike.trailPoints?.first)
        let opened = Set(hike.places.map(\.id))

        // On the hike's own screen, while the drawing waits: the hut is
        // annotated and a spring is added.
        row.apply(name: "Hut", symbol: nil, note: "Open in summer")
        let spring = TrailPlace(latitude: Line.north, longitude: Line.longitude, name: "Spring")
        hike.addPlace(spring, in: context)

        let saved = try #require(
            TrailDraftSave.update(hike, from: draft, openedWith: opened, into: context).hike
        )
        #expect(Set(saved.places.map(\.name)) == ["Hut", "Spring"], "the spring added since is not deleted")
        #expect(saved.places.first { $0.id == hut.id }?.note == "Open in summer", "nor the note reverted")
        #expect(saved.trailPoints?.contains { $0 === row } == true, "an unchanged place keeps its row")
    }

    @Test("a place removed on either side while the edit was open stays removed")
    func placesRemovedDuringTheEditStayGone() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge")
        let kept = TrailPlace(latitude: Line.south, longitude: Line.longitude, name: "Kept")
        let fromHike = TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Gone from the hike")
        let fromMaker = TrailPlace(latitude: Line.north, longitude: Line.longitude, name: "Gone from the maker")
        let found = TrailPlace(latitude: Line.further, longitude: Line.longitude, name: "Found in the maker")
        hike.replacePlaces(with: [kept, fromMaker], in: context)

        let places = TrailDraftSave.places(
            of: hike,
            drawn: [kept, fromHike, found],
            atOpen: [kept.id, fromHike.id, fromMaker.id]
        )
        #expect(Set(places.map(\.name)) == ["Kept", "Found in the maker"])
    }

    @Test("an edit forgets the library's cached climb, which was about the old line")
    func anEditClearsTheCachedClimb() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        hike.climbMeters = 120
        hike.descentMeters = 80

        _ = TrailDraftSave.update(hike, from: Self.draft([Line.south, Line.further]), openedWith: [], into: context)
        #expect(hike.climbMeters == nil)
        #expect(hike.descentMeters == nil)
    }

    @Test("editing a shared trail marks its shared copy as out of date")
    func editingASharedTrailMarksIt() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        hike.communitySubmissionID = "submission-1"
        hike.communityListingID = "listing-1"
        #expect(!hike.isSharedCopyOutOfDate)

        _ = TrailDraftSave.update(hike, from: Self.draft([Line.south, Line.further]), openedWith: [], into: context)
        #expect(hike.isSharedCopyOutOfDate)
        #expect(hike.communityListingID == "listing-1", "the publication is kept")

        hike.communitySubmissionID = "submission-2"
        #expect(!hike.isSharedCopyOutOfDate, "a fresh share is the edited route")
    }

    @Test("a refused edit leaves the hike exactly as it was")
    func aRefusedEditChangesNothing() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        try context.save()
        let route = hike.route
        let drawn = hike.drawnRouteData
        hike.climbMeters = 120

        struct Refused: Error {}
        let outcome = TrailDraftSave.update(
            hike,
            from: Self.draft([Line.south, Line.further]),
            openedWith: [],
            into: context,
            save: { _ in throw Refused() }
        )

        guard case .refused(.notSaved) = outcome else {
            Issue.record("expected the store's refusal, got \(outcome)")
            return
        }
        #expect(hike.route == route)
        #expect(hike.drawnRouteData == drawn)
        #expect(hike.climbMeters == 120)
    }

    @Test("one point is not a trail, edit or not")
    func anEditNeedsTwoPoints() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let outcome = TrailDraftSave.update(hike, from: Self.draft([Line.south]), openedWith: [], into: context)
        guard case .refused(.tooShort) = outcome else {
            Issue.record("a one-point edit should be refused")
            return
        }
    }

    // MARK: The maker

    @Test("Edit Route opens the maker on the hike's own stops and places")
    func editOpensTheStops() throws {
        let context = try Fixture.modelContext()
        let draft = Self.draft([Line.south, Line.north])
        draft.addPlaces([TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring")])
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike)
        let maker = TrailDraftController()
        let request = maker.openRequest

        #expect(maker.edit(hike))

        #expect(maker.editingHikeID == hike.id)
        #expect(maker.draft.waypoints.map(\.latitude) == [Line.south, Line.north])
        #expect(maker.draft.places.map(\.name) == ["Spring"])
        #expect(maker.openRequest != request, "and the maker is asked for")
    }

    @Test("a second Edit Route on the same hike resumes rather than starting over")
    func editResumes() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        let maker = TrailDraftController()
        maker.edit(hike)
        maker.setEditing(true)
        maker.appendWaypoint(at: Self.coordinate(Line.further))
        maker.setEditing(false)

        maker.edit(hike)
        #expect(maker.draft.waypoints.count == 3, "the stop added to the edit is still there")
    }

    @Test("a hike with no stops has nothing to edit")
    func noStopsNoEdit() throws {
        let context = try Fixture.modelContext()
        let maker = TrailDraftController()
        #expect(!maker.edit(Fixture.hike(in: context, title: "Imported")))
        #expect(maker.editingHikeID == nil)
    }

    @Test("discarding the drawing ends the edit")
    func discardEndsTheEdit() throws {
        let context = try Fixture.modelContext()
        let maker = TrailDraftController()
        maker.edit(try savedTrail(in: context))
        maker.discard()
        #expect(maker.editingHikeID == nil)
        #expect(maker.draft.isEmpty)
    }

    /// A half-finished edit resumes as an edit after a relaunch, rather than
    /// saving a second copy of the trail.
    @Test("emptying the drawing ends the edit, so the next trail drawn is a new one")
    func emptyingTheDrawingEndsTheEdit() throws {
        let context = try Fixture.modelContext()
        let maker = TrailDraftController()
        maker.edit(try savedTrail(in: context))
        maker.setEditing(true)
        maker.removeWaypoints(atOffsets: IndexSet(integersIn: 0..<maker.draft.waypoints.count))

        #expect(maker.draft.isEmpty)
        #expect(maker.editingHikeID == nil)
    }

    @Test("an edit in progress survives a relaunch as an edit")
    func anEditSurvivesALaunch() throws {
        let context = try Fixture.modelContext()
        let hike = try savedTrail(in: context)
        hike.addPlace(TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring"), in: context)
        let store = TrailDraftStore(context: context)
        TrailDraftController(store: store).edit(hike)

        let relaunched = TrailDraftController(store: store)
        relaunched.setEditing(true)
        #expect(relaunched.editingHikeID == hike.id)
        #expect(relaunched.editingPlaceIDs == Set(hike.places.map(\.id)))
        #expect(relaunched.draft.waypoints.count == 2)
        #expect(!relaunched.editingPlaceIDs.isEmpty)
    }
}
