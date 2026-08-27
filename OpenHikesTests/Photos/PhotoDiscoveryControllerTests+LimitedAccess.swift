//
//  PhotoDiscoveryControllerTests+LimitedAccess.swift
//  OpenHikesTests
//
//  The half of the discovery flow that only exists because a user can share
//  *some* of their library.
//
//  Under limited access the app is looking at a subset somebody chose by hand,
//  so "nothing here was taken during this hike" is a statement about that
//  subset and not about the library. These tests pin the two things that
//  follow from it: that the controller knows which answer it got, and that the
//  way out — the system's own picker for the shared subset — is offered
//  exactly when it would help and never when it would not.
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension rather than as
//  a second suite: SwiftLint's `single_test_class` allows one test type per
//  file, and these share every fixture with the tests next door.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// What the empty state needs in order to stop lying. Under limited
    /// access, "nothing in your library was taken during this hike" is a claim
    /// about a subset somebody chose — the photographs may be sitting right
    /// there, unshared — so the controller has to carry which answer it got.
    @Test("an empty result under limited access is distinguished from a full one")
    func emptyUnderLimitedAccessIsOfferedAWayOut() async throws {
        let library = StubPhotoLibraryFixture(access: .limited)
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .empty)
        #expect(controller.libraryAccess == .limited)
        #expect(controller.canSelectMorePhotos)
    }

    @Test("an empty result under full access offers nothing more to share")
    func emptyUnderFullAccessOffersNothing() async throws {
        let library = StubPhotoLibraryFixture(access: .granted)
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        await controller.search(in: hike)

        #expect(controller.phase == .empty)
        #expect(controller.libraryAccess == .granted)
        #expect(
            !controller.canSelectMorePhotos,
            "there is nothing left to share when the app can already see all of it"
        )
    }

    /// The way out of the dead end: the app can see a handful of photographs,
    /// the walk's own are not among them, and until now nothing in this app
    /// could change that.
    @Test("sharing more photos presents the picker and searches again")
    func selectingMorePhotosSearchesAgain() async throws {
        let library = StubPhotoLibraryFixture(
            access: .limited,
            assetsSharedByPicker: [PhotoDiscoveryFixture.asset("shared", atStep: 4)]
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        #expect(controller.phase == .empty)

        await controller.selectMorePhotos(in: hike, from: LimitedLibraryPresenter())

        #expect(library.calls.withLock(\.limitedPickerPresentations) == 1)
        #expect(library.calls.withLock(\.fetches) == 2, "the search has to be run again")
        #expect(controller.phase == .results)
        #expect(controller.matches.map(\.id) == ["shared"])
    }

    /// Closing the picker without sharing anything still costs a search, and
    /// that is the intended answer: what the picker reports is additions, and
    /// the same screen can take a photograph's access away, so only a fresh
    /// look can say what the app can now see.
    @Test("a picker closed without a change still leaves an honest empty state")
    func selectingMorePhotosSurvivesACancel() async throws {
        let library = StubPhotoLibraryFixture(access: .limited)
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)

        await controller.selectMorePhotos(in: hike, from: LimitedLibraryPresenter())

        #expect(library.calls.withLock(\.limitedPickerPresentations) == 1)
        #expect(controller.phase == .empty)
        #expect(controller.canSelectMorePhotos, "and the offer stands")
    }

    /// Nothing to widen when the app can already see everything, so the picker
    /// is never raised — it would be a system screen offered in answer to a
    /// question nobody asked.
    @Test("full access never raises the limited-library picker")
    func fullAccessNeverPresentsThePicker() async throws {
        let library = StubPhotoLibraryFixture(access: .granted)
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)

        await controller.selectMorePhotos(in: hike, from: LimitedLibraryPresenter())

        #expect(library.calls.withLock(\.limitedPickerPresentations) == 0)
        #expect(library.calls.withLock(\.fetches) == 1)
    }

    /// The counterpart of `locationRevokedMidRecording`: permission going away
    /// while the app is in the middle of using it.
    ///
    /// A revoked library answers a fetch with an empty array, which is
    /// indistinguishable from a walk nobody photographed — so a controller
    /// that only asked before the fetch would land in ``Phase/empty`` and tell
    /// the user their pictures do not exist. The gate is what makes the
    /// revocation land *during* the fetch rather than before or after it, and
    /// the wait is on the flow reaching it rather than on a duration.
    @Test("access revoked while the library is being read stops the search")
    func accessRevokedMidSearchStopsTheFlow() async throws {
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)],
            fetchGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        let searching = Task { @MainActor in await controller.search(in: hike) }
        await settleDelegateHop(until: "the search to reach the library fetch") {
            gate.isHolding
        }
        #expect(controller.phase == .searching)
        library.revokeAccess()
        gate.open()
        await searching.value

        #expect(controller.phase == .accessDenied)
        #expect(controller.phase != .empty, "a revocation is not a walk with no photos")
        #expect(controller.matches.isEmpty)
        #expect(!controller.canImport)
        #expect(library.calls.withLock(\.fetches) == 1, "and nothing is asked for twice")
    }
}
