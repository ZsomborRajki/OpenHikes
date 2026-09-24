//
//  SheetRouteTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Sheet route")
struct SheetRouteTests {
    @Test("reopening recording pops anything pushed above it")
    func reopensExistingRecording() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.recording, .hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.recording])
    }

    @Test("opening recording replaces finished-trail navigation")
    func recordingReplacesFinishedTrail() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        var path: [SheetRoute] = [.hike(hike)]

        SheetRoute.reopenRecording(in: &path)

        #expect(path == [.recording])
    }

    @Test("opening recording selects its durable hike entry")
    func recordingSelectsItsHike() throws {
        let context = try Fixture.modelContext()
        let previous = Fixture.hike(in: context, title: "Imported")
        let recording = Fixture.hike(in: context, title: "Morning Hike", route: []) { hike in
            hike.isRecording = true
        }
        var selectedHike: Hike? = previous
        var path: [SheetRoute] = [.hike(previous)]

        SheetRoute.openRecording(
            hike: recording,
            selectedHike: &selectedHike,
            in: &path
        )

        #expect(selectedHike?.id == recording.id)
        #expect(path == [.recording])
    }

    @Test("deleting a hike takes its pushed photo viewer and place screens with it")
    func photoRouteBelongsToItsHike() throws {
        let context = try Fixture.modelContext()
        let deleted = Fixture.hike(in: context, title: "Ridge Loop")
        let survivor = Fixture.hike(in: context, title: "Valley Walk")
        let path: [SheetRoute] = [
            .hike(deleted),
            .photo(deleted, UUID()),
            .place(deleted, UUID()),
            .hike(survivor),
        ]

        let remaining = path.filter { !$0.shows(hikeID: deleted.id) }

        #expect(remaining == [.hike(survivor)])
    }

    /// A walk's summary is its hike's screen, so deleting the hike pops it —
    /// through the rule `MapSheet.delete` itself calls.
    @Test("deleting a hike pops its walk summaries with it")
    func walkRouteBelongsToItsHike() throws {
        let context = try Fixture.modelContext()
        let deleted = Fixture.hike(in: context, title: "Ridge Loop")
        let survivor = Fixture.hike(in: context, title: "Valley Walk")
        let walk = HikeWalk(
            hikeID: deleted.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 600,
            coveredIntervals: [0, 500],
            furthestDistanceMeters: 500,
            routeDistanceMeters: 1000,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = deleted
        let survivorWalk = HikeWalk(
            hikeID: survivor.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 600,
            coveredIntervals: [0, 500],
            furthestDistanceMeters: 500,
            routeDistanceMeters: 1000,
            endReason: .ended
        )
        context.insert(survivorWalk)
        survivorWalk.hike = survivor
        var selectedHike: Hike? = deleted
        var path: [SheetRoute] = [.hike(deleted), .walk(walk), .hike(survivor), .walk(survivorWalk)]

        let wasSelected = SheetRoute.removeHike(deleted.id, selectedHike: &selectedHike, from: &path)

        #expect(wasSelected)
        #expect(path == [.hike(survivor), .walk(survivorWalk)])
        #expect(SheetRoute.walk(walk).shows(hikeID: deleted.id))
        #expect(!SheetRoute.walk(walk).shows(hikeID: survivor.id))
        #expect(!SheetRoute.walk(walk).prefersFullHeight)
    }

    @Test("recording is nobody's hike screen")
    func recordingShowsNoHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        #expect(SheetRoute.recording.shows(hikeID: hike.id) == false)
    }

    /// Both galleries, and whose photographs they are showing changes
    /// nothing: a picture in the medium detent is a stamp either way.
    @Test("only a photo viewer asks for the whole sheet")
    func onlyPhotoWantsFullHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let listing = CommunityListing.stub()

        #expect(SheetRoute.photo(hike, UUID()).prefersFullHeight)
        #expect(SheetRoute.communityPhoto(listing, [], 0).prefersFullHeight)
        #expect(SheetRoute.hike(hike).prefersFullHeight == false)
        #expect(SheetRoute.communityHike(listing).prefersFullHeight == false)
        #expect(SheetRoute.recording.prefersFullHeight == false)
    }

    /// A shared hike is not in the library, so deleting a hike cannot pop the
    /// gallery of one — the same answer ``SheetRoute/communityHike(_:)``
    /// gives, and for the same reason.
    @Test("a shared hike's gallery is nobody's hike screen")
    func communityPhotoShowsNoHike() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let route = SheetRoute.communityPhoto(.stub(), [], 0)

        #expect(route.shows(hikeID: hike.id) == false)
    }

    /// Identity is the listing and the page. The photographs travelling beside
    /// them are the strip as it was when it was tapped, and two pushes of the
    /// same picture of the same hike are the same screen — which is what lets
    /// ``SheetPresentation`` key a retained selection on the route.
    @Test("a shared hike's gallery is identified by its hike and its page")
    func communityPhotoIdentity() {
        let listing = CommunityListing.stub()
        let other = CommunityListing.stub(id: "ridge", submissionID: "submission-2")
        let photos = [Self.galleryPhoto(0), Self.galleryPhoto(1)]

        #expect(SheetRoute.communityPhoto(listing, photos, 1) == .communityPhoto(listing, [], 1))
        #expect(SheetRoute.communityPhoto(listing, photos, 1) != .communityPhoto(listing, photos, 0))
        #expect(SheetRoute.communityPhoto(listing, photos, 1) != .communityPhoto(other, photos, 1))
        #expect(
            SheetRoute.communityPhoto(listing, photos, 1).hashValue
                == SheetRoute.communityPhoto(listing, [], 1).hashValue
        )
    }

    private static func galleryPhoto(_ index: Int) -> CommunityGalleryPhoto {
        CommunityGalleryPhoto(
            index: index,
            pin: CommunityPhotoPin(capturedAt: .now, coordinate: nil),
            fileURL: URL(fileURLWithPath: "/tmp/community-preview/photo-\(index).jpeg")
        )
    }

    /// Hashing agrees with equality, which is what `NavigationStack` keys a
    /// pushed screen by: two pushes of one place are one screen, and a place
    /// is not its hike's photo just because they share a hike and an id.
    @Test("a route hashes the way it compares")
    func routesHashAsTheyCompare() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let id = UUID()
        let routes: Set<SheetRoute> = [
            .place(hike, id),
            .place(hike, id),
            .photo(hike, id),
            .hike(hike),
            .recording,
            .trailDraft,
        ]
        #expect(routes.count == 5)
        #expect(routes.contains(.place(hike, id)))
        #expect(!routes.contains(.place(hike, UUID())))
    }
}
