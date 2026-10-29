//
//  PhotoDiscoveryControllerTests+Reopen.swift
//  OpenHikesTests
//
//  What a reopened Find Photos sheet is first built from, and what a search or
//  an import whose sheet has closed may still do to it (#1212).
//
//  The controller outlives its sheet, and the sheet's first body pass reads
//  the phase and the matches before its `.task` has started the search that
//  withdraws them. So the section's button resets the controller in the tap
//  that presents the sheet. The first three tests close a presentation on its
//  grid, on its empty state and part-way through an import, do what that tap
//  does, and read what the first pass would. The three after them leave a
//  search and an import running across the reset, and check what a stopped
//  import hands back to the button that would close its sheet. The last
//  cancels a search while the permission prompt is up, which is what closing
//  the sheet does to its `.task`.
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
    /// Everything the sheet's first pass reads: the phase picks the screen,
    /// the matches decide the Add button, and the empty state reads the access
    /// answer. A reopened sheet has to find what a new controller holds.
    private func expectStartsOver(
        _ controller: PhotoDiscoveryController,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(controller.phase == .idle, sourceLocation: sourceLocation)
        #expect(controller.matches.isEmpty, sourceLocation: sourceLocation)
        #expect(controller.selection.isEmpty, sourceLocation: sourceLocation)
        #expect(!controller.importFailed, sourceLocation: sourceLocation)
        #expect(controller.libraryAccess == nil, sourceLocation: sourceLocation)
        #expect(!controller.canImport, sourceLocation: sourceLocation)
    }

    /// *Done* on the grid leaves its matches in the controller, and the sheet
    /// was first built from them again: the old grid, with its Add button.
    @Test("reopening after Done does not draw the last grid")
    func reopenAfterDoneStartsOver() async throws {
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        #expect(controller.phase == .results)
        // What the sheet's `onDisappear` does.
        controller.cancelImport()

        // What the section's button does before it presents the sheet again.
        controller.reset()

        expectStartsOver(controller)
    }

    /// An import that took everything closes the sheet on the empty state,
    /// which is what the reopened sheet was first built as.
    @Test("reopening after an import that took everything does not draw the empty state")
    func reopenAfterTakingEverythingStartsOver() async throws {
        let sandbox = PhotoStoreSandbox()
        let library = StubPhotoLibraryFixture(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)])
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        await controller.runImport(into: hike, store: sandbox.store)
        #expect(controller.phase == .empty)
        controller.cancelImport()

        controller.reset()

        expectStartsOver(controller)
    }

    /// A cancelled import stops before it writes its last phase, so a sheet
    /// closed part-way through one was reopened on its progress bar.
    @Test("reopening after closing mid-import does not draw its count")
    func reopenAfterClosingMidImportStartsOver() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        let importing = Task { @MainActor in
            await controller.runImport(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }
        controller.cancelImport()
        gate.open()
        _ = await importing.value
        #expect(controller.phase == .importing(completed: 0, total: 2))

        controller.reset()

        expectStartsOver(controller)
    }

    /// *Select More Photos* searches in its button's own `Task`, which closing
    /// the sheet does not cancel, so that search can still be fetching when
    /// the sheet is opened again. Its answer belongs to the presentation that
    /// has gone, and must not land between the reset and the search the new
    /// sheet starts.
    @Test("a search left running when the sheet closed writes nothing after a reset")
    func searchLeftRunningWritesNothingAfterAReset() async throws {
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)],
            fetchGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        let leftRunning = Task { @MainActor in await controller.search(in: hike) }
        await settleDelegateHop(until: "the search to reach the library fetch") {
            gate.isHolding
        }

        controller.reset()
        gate.open()
        await leftRunning.value

        expectStartsOver(controller)
    }

    /// The sheet stops a running import as it goes, and the reset stops it
    /// again, so that a clean first pass does not depend on the sheet's
    /// `onDisappear` having run before the next tap.
    @Test("an import left running writes nothing after a reset")
    func importLeftRunningWritesNothingAfterAReset() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        let importing = Task { @MainActor in
            await controller.runImport(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }

        controller.reset()
        gate.open()
        _ = await importing.value

        expectStartsOver(controller)
        #expect(library.calls.withLock(\.dataReads) == 1, "the second asset is never read")
    }

    /// The Add button closes its sheet on the count its import hands back,
    /// once nothing is left to review, which a reset leaves true. A stopped
    /// import still finishes the copy it was part-way through and returns
    /// after it, so the sheet may have been opened again by then, and the
    /// button's dismiss action, read in the presentation that has gone,
    /// closes the reopened one. So a stopped import hands back no count.
    @Test("an import stopped when its sheet closed hands back no count")
    func stoppedImportHandsBackNoCount() async throws {
        let sandbox = PhotoStoreSandbox()
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 2),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            dataGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)
        await controller.search(in: hike)
        let importing = Task { @MainActor in
            await controller.runImport(into: hike, store: sandbox.store)
        }
        await settleDelegateHop(until: "the import to reach its first asset") {
            gate.isHolding
        }

        // What the sheet's `onDisappear` does, then the section's button.
        controller.cancelImport()
        controller.reset()
        gate.open()
        let landed = await importing.value

        #expect(landed == nil, "nothing for the Add button to close a sheet on")
        #expect(
            hike.photos.map(\.assetLocalIdentifier) == ["a"],
            "though the copy that was under way still lands"
        )
    }

    /// Closing the sheet cancels its `.task`, and with it the search. A search
    /// waiting on the permission prompt learns that only when the prompt
    /// answers, and whatever the answer is, it belongs to a sheet that has
    /// gone: a refusal written then is the screen the next sheet would find
    /// first, and the answer itself is what that sheet's empty state reads.
    @Test(
        "a search cancelled while the access prompt is up writes nothing",
        arguments: [PhotoLibraryAccess.granted, .limited, .denied, .restricted]
    )
    func searchCancelledAtThePromptWritesNothing(answer: PhotoLibraryAccess) async throws {
        let gate = TestGate()
        let library = StubPhotoLibraryFixture(
            access: answer,
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)],
            accessGate: gate
        )
        let controller = PhotoDiscoveryController(reader: library)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.route)

        let searching = Task { @MainActor in await controller.search(in: hike) }
        await settleDelegateHop(until: "the search to raise the access prompt") {
            gate.isHolding
        }
        // What closing the sheet does to the search its `.task` started.
        searching.cancel()
        gate.open()
        await searching.value

        #expect(controller.phase == .searching, "no refusal is written")
        #expect(controller.libraryAccess == nil, "and no answer")
        #expect(library.calls.withLock(\.fetches) == 0)
    }
}
