//
//  PhotoDiscoveryControllerTests+Rotation.swift
//  OpenHikesTests
//
//  What a turn of the phone leaves of a Find Photos sheet, and what closing it
//  still takes away (#1462).
//
//  A turn builds the hike's screen again in the other host, and the sheet with
//  it, on the same ``PhotoDiscoverySession``. The first two tests come up a
//  second time, as the sheet's `.task` does there: once on an answer the
//  hiker has reviewed, and once on a search the turn cut off. The rest leave
//  an import running through a turn, and through the two ways a sheet is
//  really closed, and hold the Add button's close to the session's flag,
//  which is the only one a turn leaves pointing at the sheet that is up.
//
//  Split from ``PhotoDiscoveryControllerTests`` as an extension for the reason
//  the other halves are: one test type per file, and these share every
//  fixture with the tests next door.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

extension PhotoDiscoveryControllerTests {
    /// The sheet's `.task` comes up again after a turn, and a search there put
    /// back every photograph the hiker had taken out of the grid.
    @Test("a sheet built again after a turn keeps the hiker's choice and asks nothing")
    func aTurnKeepsTheReviewedAnswer() async throws {
        let library = StubPhotoLibraryFixture(assets: [
            PhotoDiscoveryFixture.asset("a", atStep: 2),
            PhotoDiscoveryFixture.asset("b", atStep: 5),
        ])
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let controller = session.controller
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        await controller.searchUnlessAnswered(in: hike)
        #expect(controller.selection == ["a", "b"], "precondition: everything arrives ticked")
        controller.toggle("a")

        // What the old host's `onDismiss` does in a turn, then the new
        // sheet's `.task`.
        session.closed()
        await controller.searchUnlessAnswered(in: hike)

        #expect(session.isPresented)
        #expect(controller.phase == .results)
        #expect(controller.selection == ["b"], "the photograph taken out stays out")
        #expect(library.calls.withLock(\.fetches) == 1, "and the library is not asked again")
    }

    /// A turn cancels the `.task` of the sheet it takes away, search and all,
    /// and a cancelled search writes nothing — not even an end to its
    /// spinner. The sheet built again asks again.
    @Test("a search the turn cut off is asked again")
    func aSearchCutOffByATurnIsAskedAgain() async throws {
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)],
            fetchGate: gate
        )
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let controller = session.controller
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        let cutOff = Task { @MainActor in await controller.searchUnlessAnswered(in: hike) }
        await settleDelegateHop(until: "the search to reach the library fetch") {
            gate.isHolding
        }
        cutOff.cancel()
        gate.open()
        await cutOff.value
        #expect(controller.phase == .searching, "precondition: the cut-off search wrote nothing")

        await controller.searchUnlessAnswered(in: hike)

        #expect(controller.phase == .results)
        #expect(controller.selection == ["a"])
    }

    /// The import the hiker started goes on through a turn, into the sheet
    /// the other host presents again, and closes that sheet once everything
    /// has landed. The Add button used to close it with the dismiss action
    /// of the sheet the turn took away, which closed nothing, and left the
    /// sheet up saying no photos were found.
    @Test("an import goes on through a turn")
    func anImportGoesOnThroughATurn() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let controller = session.controller
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        await controller.searchUnlessAnswered(in: hike)
        // What the Add button does.
        let importing = Task { @MainActor in
            await session.importChosen(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }

        session.closed()
        #expect(session.isPresented, "precondition: a turn leaves the sheet up")
        gate.open()
        await importing.value

        #expect(controller.phase == .empty)
        #expect(Set(hike.photos.compactMap(\.assetLocalIdentifier)) == ["a", "b"])
        #expect(!session.isPresented, "and the sheet up when it ends is closed")
    }

    /// The case the button's count was withheld for: closed mid-import and
    /// opened again, the sheet now up is a new question, and the import the
    /// first one started must not close it.
    @Test("an import stopped by a close leaves the sheet opened since up")
    func aStoppedImportLeavesTheReopenedSheetUp() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        await session.controller.searchUnlessAnswered(in: hike)
        let importing = Task { @MainActor in
            await session.importChosen(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }

        // *Done*, then *Find Photos of This Hike* again.
        session.isPresented = false
        session.closed()
        session.start()
        gate.open()
        await importing.value

        #expect(session.isPresented)
        #expect(session.controller.phase == .idle, "on the new question, untouched")
    }

    /// A photograph that could not be copied stays in the grid to be tried
    /// again, so the sheet stays up on it.
    @Test("an import that left a photograph behind keeps the sheet up")
    func aPartialImportKeepsTheSheetUp() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            unreadable: ["b"]
        )
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        await session.controller.searchUnlessAnswered(in: hike)

        await session.importChosen(into: hike, store: sandbox.store)

        #expect(session.controller.phase == .results)
        #expect(session.controller.importFailed)
        #expect(session.isPresented)
    }

    /// *Done* or a swipe writes the flag back before the sheet has gone; the
    /// hike's screens leaving the stack write nothing, and end the session
    /// instead. Either stops the import, keeping the copy under way, and
    /// hands the Add button no count.
    @Test("closing the sheet, or its hike's screens going, stops the import", arguments: [false, true])
    func closingStopsTheImport(byLeavingTheHike: Bool) async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let session = PhotoDiscoverySession(controller: PhotoDiscoveryController(reader: library))
        let controller = session.controller
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        session.start()
        await controller.searchUnlessAnswered(in: hike)
        let importing = Task { @MainActor in
            await controller.runImport(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }

        if byLeavingTheHike {
            session.end()
        } else {
            session.isPresented = false
            session.closed()
        }
        gate.open()
        let landed = await importing.value

        #expect(!session.isPresented)
        #expect(landed == nil, "nothing for the Add button to close a sheet on")
        #expect(hike.photos.map(\.assetLocalIdentifier) == ["a"], "though the copy under way still lands")
        #expect(library.calls.withLock(\.dataReads) == 1, "and the second photograph is never read")
    }
}
