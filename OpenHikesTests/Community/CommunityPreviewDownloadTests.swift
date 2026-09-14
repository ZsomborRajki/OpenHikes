//
//  CommunityPreviewDownloadTests.swift
//  OpenHikesTests
//
//  When a preview's downloads are allowed to go, and what must have finished
//  first.
//
//  These are somebody else's photographs, held for as long as the screen
//  showing them and no longer — which cuts both ways, and the second way is
//  the one that was wrong. Deleting the directory while the *import* is
//  reading out of it costs the hiker the pictures of a hike they asked for;
//  deleting it while the *download* is still writing into it leaves files
//  behind instead, because the writer re-creates the directory after the
//  remove and nothing ever comes back for it.
//
//  Asserted against the ordering rather than against the view, for the reason
//  `CommunityPhotoPairingTests` is `CKRecord`-free: what is worth pinning is
//  invisible in the result. A discard that waited and a discard that raced
//  both leave no directory on a good day.
//
//  The last test here is about the other half of backing out: what the load
//  does with a detail that arrives anyway. Cancelling it is not enough on its
//  own, because the transport's last cancellation check comes *before* it
//  copies the photographs and a copy that finishes hands back a detail rather
//  than throwing — and the work the load starts next includes an unstructured
//  task that inherits no cancellation and is not yet held anywhere
//  `onDisappear` can reach.
//
//  The last three are about *whose* directory is being removed rather than
//  when. Waiting for a visit's own work is the whole protection, and it is no
//  protection at all against a second visit to the same listing: that one has
//  its own tasks, the discard left over from the first visit has never heard
//  of them, and both were reading and writing the same path. So the name now
//  carries the visit — see ``CommunityStaging/previewDirectory(of:in:)`` —
//  and these pin what that name has to keep apart and what it has to hold
//  still.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@MainActor
@Suite("Community preview downloads")
struct CommunityPreviewDownloadTests {
    /// A directory with a file in it, so a premature remove is something a
    /// test can see rather than something it has to infer.
    private func downloadDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityHikeTest-\(UUID().uuidString)", isDirectory: true)
        try photograph(in: directory)
        return directory
    }

    /// Puts a stranger's photograph in a preview's directory and hands back the
    /// file, so a test can ask after *that* rather than after the directory —
    /// which is the difference the per-visit name is for: a discard that takes
    /// the wrong directory takes the photographs in it.
    @discardableResult private func photograph(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = directory.appendingPathComponent("photo-0.jpeg")
        try Data("photo".utf8).write(to: photo)
        return photo
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Clears up a directory the discard under test was supposed to *spare*.
    /// The suite's other cases end with nothing left in the temporary
    /// directory because the thing they are testing removes it; the ones that
    /// assert a directory survived have to do it themselves.
    private func remove(_ directories: URL...) {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The discard is fire-and-forget off a detached task, so this waits for
    /// the directory to go rather than for a length of time — the same shape
    /// `CommunityStagingTests` waits for a staging directory in.
    private func settleRemoval(of directory: URL) async {
        await settleDelegateHop(until: "the download directory to be deleted") {
            !exists(directory)
        }
    }

    /// The reported bug. Backing out mid-download left the load running: the
    /// remove landed first, and the download then re-created the directory and
    /// wrote a stranger's photographs into it, where nothing would ever
    /// collect them.
    @Test("a download still running holds the directory open")
    func anUnfinishedDownloadDelaysTheRemoval() async throws {
        let directory = try downloadDirectory()
        let gate = AsyncGate()
        let download = Task { await gate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [download, nil])

        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory), "the directory went while a download was still writing into it")

        await gate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// The half that was already right, and must stay right: the import is
    /// reading a stranger's photographs out of here, and deleting underneath
    /// it costs the hiker the pictures of a hike they asked for.
    @Test("an import still running holds the directory open")
    func anUnfinishedImportDelaysTheRemoval() async throws {
        let directory = try downloadDirectory()
        let gate = AsyncGate()
        let importing = Task { await gate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [nil, importing])

        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory))

        await gate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// Both at once is the ordinary shape of leaving a screen mid-import, and
    /// neither one finishing is enough on its own.
    @Test("the directory outlives whichever finishes first")
    func bothMustFinishBeforeTheRemoval() async throws {
        let directory = try downloadDirectory()
        let downloadGate = AsyncGate()
        let importGate = AsyncGate()
        let download = Task { await downloadGate.wait() }
        let importing = Task { await importGate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [download, importing])

        await downloadGate.open()
        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory), "one of the two finishing is not enough")

        await importGate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// The reported bug's twin, one step later. The hiker backs out while a
    /// stranger's photographs are being copied: the transport has already made
    /// its last cancellation check, so the copy finishes and the detail comes
    /// back successfully into a load that has been cancelled.
    ///
    /// What that costs is not the directory — the discard above covers that —
    /// but the trail analysis, which `load()` starts in an unstructured `Task`
    /// straight after this call. That task inherits no cancellation, and
    /// `onDisappear` has already run by the time it exists, so its own
    /// `Task.isCancelled` guard is false and it would spend up to
    /// ``TrailGraphProviding/maximumPrefetchRegions`` Overpass requests on a
    /// preview that has gone. Refusing the detail here is what keeps `load()`
    /// from ever reaching it: the throw lands in the branch that returns
    /// without touching the phase.
    ///
    /// Pinned at the fetch rather than through the view because the analysis
    /// is spawned from `@State` a suite cannot install — and because a
    /// cancellation that was checked and one that was missed hand back the
    /// same detail on any day the hiker stays.
    @Test("a detail that lands after the hiker leaves is refused")
    func aCancelledLoadRefusesTheDetail() async throws {
        // Never created: the stub writes nothing, and what is under test is
        // the check made after the transport has returned.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityHikeTest-\(UUID().uuidString)", isDirectory: true)
        let transport = StubCommunityTransport()
        transport.detailResult = .success(
            CommunityHikeDetail(
                listing: .stub(),
                route: Fixture.ridgeRoute,
                trackDescription: "A ridge walk",
                photoPins: [],
                photoFileURLs: [],
                photosOnRecord: 0
            )
        )
        // Held open where the production transport is copying photographs,
        // which is past the last cancellation check it makes.
        let gate = AsyncGate()
        transport.beforeDetailReturns = { await gate.wait() }

        let load = Task {
            try await CommunityHikeView.detail(
                of: .stub(),
                from: transport,
                downloadingInto: directory
            )
        }
        await settleDelegateHop(until: "the detail request to reach the transport") {
            !transport.recording.detailRequests.isEmpty
        }

        load.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await load.value
        }
    }

    /// A preview the hiker backed out of before anything started, which is the
    /// common case and must not wait on anything.
    @Test("nothing in flight removes the directory at once")
    func nothingPendingRemovesImmediately() async throws {
        let directory = try downloadDirectory()

        CommunityHikeView.discardDownloads(at: directory, after: [nil, nil])

        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// The gesture the waiting above cannot survive: open a hike, back out
    /// while its download is still running, open the *same* hike again, and let
    /// the first visit's work finish underneath the second one.
    ///
    /// The first visit's discard is still pending — that is what the wait is
    /// for — and it removes a path. While the path carried only the listing,
    /// the path it removed was the one the second visit had just downloaded a
    /// stranger's photographs into, and the import reading them would find
    /// nothing there. Nothing in the first visit's task list mentions the
    /// second visit, and nothing could: the second visit did not exist when the
    /// discard was handed its work.
    @Test("a reopened preview keeps the photographs the last visit's cleanup wanted")
    func aReopenedVisitOutlivesTheDiscardOfTheOneBeforeIt() async throws {
        let listing = CommunityListing.stub()
        let left = CommunityStaging.previewDirectory(of: listing, in: UUID())
        let reopened = CommunityStaging.previewDirectory(of: listing, in: UUID())
        #expect(left != reopened, "two visits to one listing were handed one directory")

        try photograph(in: left)
        let photo = try photograph(in: reopened)

        // The download the hiker backed out of, still going: the only reason
        // the first visit's directory is still here to be removed at all.
        let gate = AsyncGate()
        let stranded = Task { await gate.wait() }
        CommunityHikeView.discardDownloads(at: left, after: [stranded, nil])

        await gate.open()
        await settleRemoval(of: left)
        #expect(
            exists(photo),
            "the departed visit's cleanup took the reopened preview's photographs"
        )
        remove(reopened)
    }

    /// The other half of the same name, and the half a fresh directory per
    /// *screen* would have broken: a push over an open preview is not the hiker
    /// leaving it, `onDisappear` declines to discard for one — see
    /// `remainsPushed` — and the view that comes back has to come back to its
    /// own downloads rather than to a name nothing was ever written under.
    @Test("a preview pushed over and returned to keeps one directory")
    func oneVisitKeepsOneDirectoryAcrossAPush() throws {
        let listing = CommunityListing.stub()
        let visit = UUID()

        let onOpening = CommunityStaging.previewDirectory(of: listing, in: visit)
        let photo = try photograph(in: onOpening)
        let onReturning = CommunityStaging.previewDirectory(of: listing, in: visit)

        #expect(onOpening == onReturning, "one visit was given two directories")
        #expect(exists(photo))
        remove(onOpening)
    }

    /// A → B → A: a pin on the map pushes a second preview over an open one,
    /// and backing out of that one discards it while the first is still sitting
    /// underneath with its photographs loaded and its detail pointing at them.
    @Test("backing out of a preview pushed over another spares the first")
    func aPushedPreviewsDiscardSparesTheOneUnderneath() async throws {
        let underneath = CommunityStaging.previewDirectory(
            of: .stub(id: "listing-1"),
            in: UUID()
        )
        let pushedOver = CommunityStaging.previewDirectory(
            of: .stub(id: "listing-2"),
            in: UUID()
        )
        let photo = try photograph(in: underneath)
        try photograph(in: pushedOver)

        CommunityHikeView.discardDownloads(at: pushedOver, after: [nil, nil])

        await settleRemoval(of: pushedOver)
        #expect(exists(photo), "backing out of the pushed preview took the first one's photographs")
        remove(underneath)
    }
}
