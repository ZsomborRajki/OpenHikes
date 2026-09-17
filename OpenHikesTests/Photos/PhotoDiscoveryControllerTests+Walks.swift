//
//  PhotoDiscoveryControllerTests+Walks.swift
//  OpenHikesTests
//
//  The flow end to end on the trail this feature used to miss entirely: a
//  route imported from a GPX, walked with OpenHikes, photographed with the
//  system camera.
//
//  ``HikePhotoSearchPlanTests`` pins which clock answers for a photograph.
//  What is asserted here is the part only the controller can be asked about —
//  that such a hike is no longer reported as unsupported, that the fetch is
//  narrowed to the walk rather than opened across the years between an
//  imported track and the afternoon it was walked, and that what lands on the
//  hike is a real file with the walk's own evidence on it.
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension for the reason
//  the limited-access half is: one test type per file, and these share every
//  fixture with the tests next door.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// A hike whose route carries no timestamps is `unsupported` until
    /// somebody walks it — and then it is not. The same route, the same
    /// library, one `HikeWalk` between them.
    @Test("an imported route that has been walked is searchable")
    func walkedImportedRouteFindsItsPhotos() async throws {
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 4.5)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)

        await controller.search(in: hike)
        #expect(controller.phase == .unsupported)

        Self.addWalk(to: hike, in: context)
        await controller.search(in: hike)

        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["a"])
        #expect(controller.matches.first?.evidence == .walk)
        #expect(controller.canImport)
    }

    /// One window, not the span between the day the track was recorded and the
    /// day it was walked — which on an imported trail is routinely years.
    @Test("the fetch is narrowed to the walk itself")
    func fetchIsNarrowedToTheWalk() async throws {
        let library = StubPhotoLibraryFixture()
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        await controller.search(in: hike)

        // Read out of the mutex first: `#require` cannot take a borrow of a
        // non-copyable `Mutex` through its macro expansion.
        let lastWindow = library.calls.withLock(\.lastWindow)
        let window = try #require(lastWindow)
        #expect(library.calls.withLock(\.fetches) == 1)
        #expect(
            window.lowerBound
                == PhotoDiscoveryFixture.date(atStep: 0)
                .addingTimeInterval(-HikePhotoTimeline.graceInterval)
        )
        #expect(
            window.upperBound
                == PhotoDiscoveryFixture.date(atStep: 9)
                .addingTimeInterval(HikePhotoTimeline.graceInterval)
        )
    }

    /// The import path is the one already in place, so what is checked here is
    /// only that a walk-placed match survives it: the file is written, the
    /// asset identity travels so a second scan skips it, and the evidence
    /// stored is the walk's rather than a stronger claim.
    @Test("a walk-placed photo imports with its evidence intact")
    func walkPlacedPhotoImports() async throws {
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 4.5)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let sandbox = PhotoStoreSandbox()
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        await controller.search(in: hike)
        let landed = await controller.runImport(into: hike, store: sandbox.store)

        #expect(landed == 1)
        let photo = try #require(hike.photos.first)
        #expect(photo.matchEvidence == .walk)
        #expect(photo.assetLocalIdentifier == "a")
        #expect(photo.isAnchored)

        // A second scan offers nothing: the identifier is what stops the same
        // picture being attached twice.
        await controller.search(in: hike)
        #expect(controller.phase == .empty)
    }

    /// A walk of the whole fixture route, from its first point to its last.
    private static func addWalk(to hike: Hike, in context: ModelContext) {
        let profile = RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute)
        let walk = PhotoDiscoveryFixture.walk(
            hikeID: hike.id,
            fromStep: 0,
            toStep: 9,
            covering: 0...profile.totalDistanceMeters,
            routeDistanceMeters: profile.totalDistanceMeters
        )
        context.insert(walk)
        walk.hike = hike
    }
}
