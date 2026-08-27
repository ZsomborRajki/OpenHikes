//
//  PhotoDiscoveryControllerTests.swift
//  OpenHikesTests
//
//  The state machine between the button and the photos: ask, search, offer,
//  import.
//
//  Driven against a stub library for the three reasons ``PhotoLibrarySource``
//  lays out — a `PHAsset` cannot be constructed, an authorization prompt
//  cannot be answered from a test, and the Simulator's library holds whatever
//  the last person to use it left there. Everything below the library is real:
//  the matcher, ``HikePhotoImport``, and a ``HikePhotoStore`` rooted in a
//  temporary directory, so what a passing test has watched is files landing on
//  disk and metadata landing on a `Hike`.
//
//  The two orderings worth pinning are both about not asking for things. A
//  hike whose route carries no timestamps must reach `empty` without the
//  permission prompt ever being raised — prompting for access to somebody's
//  photo library in order to then tell them the feature cannot work is the
//  worst possible sequence. And a refusal must stop the flow before the fetch,
//  rather than fetching and finding nothing.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Synchronization
import Testing

@Suite("Photo discovery controller")
struct PhotoDiscoveryControllerTests {
    /// The button that opens this flow is offered on every hike, including the
    /// ones it cannot possibly match on — so the sheet has to be able to say
    /// *why* nothing happened, and has to be able to say it without spending
    /// somebody's photo-library permission to find out.
    ///
    /// Both halves are asserted here: the phase is ``Phase/unsupported`` and
    /// not ``Phase/empty``, which is what lets the sheet distinguish "this
    /// route has no clock on it" from "your library had nothing from that
    /// day"; and neither the prompt nor the fetch was reached.
    @Test("a hike with no timestamps is unsupported, and raises no prompt")
    func hikeWithoutTimestampsAsksForNothing() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(
            in: context,
            route: [
                RouteCoordinate(
                    latitude: PhotoDiscoveryFixture.latitude,
                    longitude: PhotoDiscoveryFixture.longitude
                ),
            ]
        )

        await controller.search(in: hike)

        #expect(controller.phase == .unsupported)
        #expect(controller.phase != .empty)
        #expect(!controller.canImport)
        #expect(library.calls.withLock(\.accessRequests) == 0)
        #expect(library.calls.withLock(\.fetches) == 0)
    }

    @Test("a refusal stops the flow before the library is read")
    func refusedAccessStopsBeforeTheFetch() async throws {
        let library = StubPhotoLibraryFixture(
            access: .denied,
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .accessDenied)
        #expect(library.calls.withLock(\.fetches) == 0)
    }

    @Test("a restricted library is distinguished from a refused one")
    func restrictedAccessHasItsOwnPhase() async throws {
        let library = StubPhotoLibraryFixture(access: .restricted)
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .accessRestricted)
    }

    /// Limited access is a first-class answer, not a degraded one: the user
    /// chose which photos this app may see, which is exactly the right shape
    /// for a feature that wants a handful of them.
    @Test("limited access searches as normal")
    func limitedAccessStillSearches() async throws {
        let library = StubPhotoLibraryFixture(
            access: .limited,
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .results)
        #expect(controller.matches.count == 1)
    }

    @Test("the fetch is narrowed to the walk's own window")
    func fetchUsesTheWalkWindow() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        let timeline = try #require(hike.photoTimeline)
        #expect(library.calls.withLock(\.lastWindow) == timeline.searchWindow)
    }

    @Test("results arrive selected, so the common answer needs one tap")
    func resultsArriveSelected() async throws {
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .results)
        #expect(controller.selection == ["a", "b"])
        #expect(controller.canImport)
    }

    @Test("a library with nothing from this walk reaches the empty state")
    func noMatchesReachesEmpty() async throws {
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoLibraryAsset(
                    localIdentifier: "elsewhere",
                    createdAt: PhotoDiscoveryFixture.date(atStep: 1000)
                ),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .empty)
        #expect(!controller.canImport)
    }

    @Test("deselecting everything disables the import")
    func deselectingEverythingDisablesImport() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)

        controller.toggle("a")

        #expect(!controller.isSelected("a"))
        #expect(!controller.canImport)
        controller.selectAll()
        #expect(controller.canImport)
    }

    @Test("importing writes the photo, its anchor, its moment and its origin")
    func importAttachesEverythingItLearned() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 3)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)

        let imported = await controller.importSelected(
            into: hike,
            store: sandbox.store
        )

        #expect(imported == 1)
        let photo = try #require(hike.photos.first)
        #expect(photo.assetLocalIdentifier == "a")
        #expect(photo.matchEvidence == .time)
        #expect(photo.capturedAt == PhotoDiscoveryFixture.date(atStep: 3))
        #expect(photo.isAnchored)
        #expect(
            FileManager.default.fileExists(
                atPath: sandbox.store.url(for: photo).path
            )
        )
    }

    @Test("only the selected photos are imported")
    func importTakesOnlyTheSelection() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        controller.toggle("b")

        await controller.importSelected(into: hike, store: sandbox.store)

        #expect(hike.photos.map(\.assetLocalIdentifier) == ["a"])
        // What was not taken is still on offer.
        #expect(controller.matches.map(\.id) == ["b"])
    }

    /// The whole reason ``HikePhoto/assetLocalIdentifier`` is persisted:
    /// scanning twice must not offer — or attach — the same picture again.
    @Test("a second search skips what the first one took")
    func secondSearchSkipsImportedPhotos() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        await controller.importSelected(into: hike, store: sandbox.store)

        await controller.search(in: hike)

        #expect(controller.phase == .empty)
        #expect(controller.matches.isEmpty)
        #expect(hike.photos.count == 2)
    }

    /// A photo that could not be copied out of the library is reported and
    /// left on offer; the ones that landed are still the user's.
    @Test("a failed copy keeps the rest and stays retryable")
    func failedCopyKeepsTheRest() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            unreadable: ["b"]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)

        let imported = await controller.importSelected(
            into: hike,
            store: sandbox.store
        )

        #expect(imported == 1)
        #expect(controller.importFailed)
        #expect(hike.photos.map(\.assetLocalIdentifier) == ["a"])
        #expect(controller.matches.map(\.id) == ["b"])
    }

    /// The window the user can pop back and delete the hike in. SwiftData
    /// detaches a deleted model rather than invalidating it, so an unguarded
    /// import would append metadata to an object nothing will ever persist and
    /// leave a file on disk with nothing left to claim it.
    @Test("a hike deleted mid-import stops the import")
    func deletedHikeStopsTheImport() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        context.delete(hike)
        try context.save()

        let imported = await controller.importSelected(
            into: hike,
            store: sandbox.store
        )

        #expect(imported == 0)
        #expect(library.calls.withLock(\.dataReads) == 0)
    }
}
