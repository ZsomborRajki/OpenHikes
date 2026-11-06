//
//  SheetPoppedDestinationTests.swift
//  OpenHikesTests
//
//  The last build of a screen being popped (#1352).
//
//  `MapSheet` builds every pushed screen in one closure that reads the path,
//  so a pop builds the screen it is taking away once more, after the path has
//  lost its route. Each lookup made a new, empty object there, and the screen
//  slid out reset — a shared hike's preview showing *Loading route…*, *Places
//  Around Trail* with nothing found, *Add Place* back to its kind's name. Every
//  kind of object ``SheetPresentation`` keeps for a screen is held here to the
//  same rule, which ``SheetRetained`` keeps for all of them: that build draws
//  what the screen had, and pushing the route again starts over.
//
//  ``SheetDestinationStateTests`` holds what each object keeps through a turn
//  of the phone, and what a pop stops.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("A popped screen's last build")
struct SheetPoppedDestinationTests {
    @Test("a hike's screen and the screens over one are built on what they had as they go")
    func aHikesScreensKeepWhatTheyHadOnTheWayOut() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        // `HikeDetailView`'s `.equatable()` compares its interaction by
        // identity, so a new one there ran the screen's body again, on the
        // first segment and an unread line.
        expectKept(pushing: [.hike(hike)]) { $0.hikeInteraction(for: hike) }

        let photo = SheetRoute.photo(hike, UUID())
        expectKept(pushing: [.hike(hike), photo], poppingTo: [.hike(hike)]) { $0.photoSelection(for: photo) }

        let adder = SheetRoute.newPlace(hike, HikePlaceSpot(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.9)))
        expectKept(pushing: [.hike(hike), adder], poppingTo: [.hike(hike)]) { $0.placeAdder(for: adder) }

        let around = SheetRoute.placesAround(hike)
        expectKept(pushing: [.hike(hike), around], poppingTo: [.hike(hike)]) { $0.placesAroundSearch(for: around) }

        let nearby = SheetRoute.placesNearby(hike)
        expectKept(pushing: [.recording, nearby], poppingTo: [.recording]) { $0.placesNearby(for: nearby) }

        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 600,
            coveredIntervals: [0, 500],
            furthestDistanceMeters: 500,
            routeDistanceMeters: 1000,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = hike
        let summary = SheetRoute.walk(walk)
        expectKept(pushing: [.hike(hike), summary], poppingTo: [.hike(hike)]) { $0.walkShare(for: summary) }
    }

    @Test("the shared screens are built on what they had as they go")
    func theSharedScreensKeepWhatTheyHadOnTheWayOut() {
        let listing = CommunityListing.stub()
        expectKept(pushing: [.communityHike(listing)]) { $0.communityPreview(of: listing) }

        let gallery = SheetRoute.communityPhoto(listing, [], 0)
        expectKept(pushing: [.communityHike(listing), gallery], poppingTo: [.communityHike(listing)]) { presentation in
            presentation.communityPhotoSelection(for: gallery)
        }

        let submission = CommunityPendingSubmission.stub()
        expectKept(pushing: [.pendingSubmission(submission)]) { $0.review(of: submission) }

        let photos = CommunityPendingPhotos.stub()
        expectKept(pushing: [.pendingPhotos(photos)]) { $0.review(of: photos) }
    }

    @Test("what a pop let go of is handed on only until the path changes again")
    func theAsideLastsOneChangeOfPath() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let around = SheetRoute.placesAround(hike)
        let presentation = SheetPresentation()
        presentation.path = [.hike(hike), around]
        let search = presentation.placesAroundSearch(for: around)

        presentation.path = [.hike(hike)]
        #expect(presentation.placesAroundSearch(for: around) === search)
        presentation.path.append(.place(hike, UUID()))
        #expect(presentation.placesAroundSearch(for: around) !== search, "nothing is held past the next change")
    }
}

/// Pushes `path`, takes what `lookup` hands its screen, pops to `popped`, and
/// holds the builds on the way out to that object and the next push to a new
/// one.
@MainActor
private func expectKept<Value: AnyObject>(
    pushing path: [SheetRoute],
    poppingTo popped: [SheetRoute] = [],
    sourceLocation: SourceLocation = #_sourceLocation,
    _ lookup: (SheetPresentation) -> Value
) {
    let presentation = SheetPresentation()
    presentation.path = path
    let shown = lookup(presentation)

    presentation.path = popped
    #expect(lookup(presentation) === shown, "the screen going draws what it had", sourceLocation: sourceLocation)
    #expect(lookup(presentation) === shown, "however often it is built on its way", sourceLocation: sourceLocation)

    presentation.path = path
    let next = lookup(presentation)
    #expect(next !== shown, "pushing it again starts over", sourceLocation: sourceLocation)
    #expect(lookup(presentation) === next, sourceLocation: sourceLocation)
}
