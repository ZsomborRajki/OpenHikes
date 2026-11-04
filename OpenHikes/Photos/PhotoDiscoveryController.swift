//
//  PhotoDiscoveryController.swift
//  OpenHikes
//
//  The state behind "Find Photos of This Hike": ask, search, offer, import.
//
//  A reference type observed by one sheet, for the ordinary reason — the
//  search is a `Task` that outlives a view body, and the selection has to
//  survive the grid being rebuilt as thumbnails land. Nothing else in the app
//  observes it, and the model does not own it: ``HikePhotoSection`` keeps it
//  in `@State`, on the *Details* face of a hike's screen, so it lives as long
//  as that section rather than as long as the sheet. Dismissing the sheet
//  disposes of nothing, and opening it again hands the new presentation the
//  same controller, once the section's button has reset it (below). Only a
//  new section makes a new one: opening the hike again, flipping its screen
//  to *History* and back, or a turn or an iPhone Duo opening or closing that
//  moves the screen between the sheet and the side panel — see *The map
//  screen* in the repository instructions.
//
//  None of what the last presentation left reaches the next one. Each search
//  withdraws the previous results before it first suspends, and the sheet
//  cancels a running import as it goes, because an import left running would
//  write into the state the next search is filling, and a stopped import
//  hands its Add button no count to close a sheet on — see ``search(in:)``
//  and ``runImport(into:store:)``. The withdrawal comes after a reopened
//  sheet's first body pass, though, because the search is started by the
//  `.task` that pass attaches. So the section's button also resets the
//  controller before it presents the sheet, and that pass is built from
//  nothing the last presentation left — see ``reset()``.
//
//  Three things are worth stating about the order it does its work in.
//
//  Permission is asked for after the plan is built, not before. A hike with
//  neither a stamped route nor a walk along it has nothing to match against,
//  and prompting for access to somebody's photo library in order to then tell
//  them the feature cannot work is the worst possible sequence.
//
//  Nothing is imported without being shown first. The match is a good guess
//  and is presented as one: the user sees each picture, sees how it was
//  placed, and taps the ones that belong. A scan that silently attached
//  twenty pictures would be a scan nobody could undo in one gesture.
//
//  An import that fails partway keeps what it managed. Each photo is written
//  through ``HikePhotoImport``, which stores the app's own copy before
//  anything else — so a picture that made it is a picture the user has, and
//  the ones that did not are still in their library, untouched.
//
//  And a search that finds nothing has to be honest about *why*. Under
//  limited access the app is looking at a subset somebody chose, so "nothing
//  from this walk" is a statement about that subset and not about the
//  library; ``libraryAccess`` is kept for the sheet to say so, and
//  ``selectMorePhotos(in:from:)`` is the way out.
//
//  The route-sized work — reading the route, indexing it, matching the
//  library's answer against it — runs off the main actor, through
//  ``PhotoDiscoveryWork``. Here the hike is only named before the hop, unless
//  it holds edits its store has not had yet, which are read here — see
//  ``HikePhotoSearchPlan/SourceRead``. Only the newest search writes what
//  comes back: the sheet starts one per presentation, and the picker for the
//  shared subset starts another, so an older one still matching must not land
//  its answer on top of the newer one's.
//
//  A plan is one reading of the hike, and everything after that reading is a
//  wait: the prompt, the library, the matcher, then the hiker with the grid up,
//  then each photograph's bytes. A line mirrored in from the hiker's other
//  device, or an edit made here, can land in any of them, and the pins in the
//  grid would stay the old line's, all the way into Add storing them (#1280).
//  So what the plan was built from is kept as a fingerprint, and set beside
//  what the store holds at the three moments that decide anything: before a
//  search writes what it found, at each save of the store while the sheet is
//  up (``followSaves(of:)``), and before each photograph is attached, once its
//  bytes are on disk. The store is what is asked, because only it can answer
//  for a line received from another device, or for a walk. It is read as the
//  plan was, off the main actor, and each look costs that read and no
//  indexing.
//
//  A plan the hike has left is replaced rather than only withdrawn. The hiker
//  asked for these photographs and the question still stands, so the same
//  question is asked of the new line, the grid comes back, and what they had
//  unticked stays unticked. What already landed stays where it landed, as
//  every photo already on a hike stays through an edit.
//

import Foundation
import Observation
import OpenHikesData
import SwiftData
import SwiftUI

@Observable
@MainActor
final class PhotoDiscoveryController {
    /// Longest edge of a review-grid thumbnail, in pixels. Comfortably over
    /// the cell at 3×, and far under a capture.
    static let thumbnailPixelSize = 400

    /// Where the flow is, as one value rather than as four booleans that can
    /// contradict each other.
    enum Phase: Equatable {
        /// The user refused, or has not been asked and the prompt came back
        /// negative. Recoverable in Settings, so the sheet says so.
        case accessDenied
        /// A managed device or Screen Time. Nothing to offer and nowhere to
        /// send them.
        case accessRestricted
        /// The search ran and this walk has no unattached photos. Distinct
        /// from ``results`` with an empty array so the sheet can say which
        /// question came back empty.
        case empty
        case idle
        /// Writing the chosen photos into the hike. Carries its progress so
        /// the button can count rather than spin.
        case importing(completed: Int, total: Int)
        case results
        case searching
        /// Neither the route nor any walk along it can place a photograph:
        /// the points carry no timestamps and the trail has never been
        /// walked with this app. Distinct from ``empty``, which means the
        /// question was asked and came back with nothing: here it was never
        /// askable, and the sheet says so rather than reporting a search it
        /// did not run.
        case unsupported
    }

    private(set) var phase = Phase.idle
    /// What the library last said it would let the app do.
    ///
    /// Kept because an empty result means two different things depending on
    /// the answer, and the sheet has to say which: under full access nothing
    /// in the library was taken during this walk, while under
    /// ``PhotoLibraryAccess/limited`` nothing *the user shared* was — and the
    /// photographs may well be sitting there unshared. `nil` until a search
    /// has asked.
    private(set) var libraryAccess: PhotoLibraryAccess?
    /// Everything the search turned up, oldest first.
    private(set) var matches: [LibraryPhotoMatch] = []
    /// Which of them the user wants, by local identifier. Everything is
    /// selected when the results arrive — the common case is "yes, all of
    /// these are from my walk", and the alternative is a screen that opens
    /// with a disabled button.
    var selection: Set<String> = []
    /// Set when at least one chosen photo could not be copied out of the
    /// library or written to disk. The rest still landed.
    private(set) var importFailed = false

    private let reader: any PhotoLibraryReading
    private let work: PhotoDiscoveryWork
    /// Counts searches, so one that a newer search has overtaken can tell and
    /// write nothing — see ``search(in:)``.
    @ObservationIgnored private var searchGeneration = 0
    /// What the plan behind ``matches`` was built from, to set beside what
    /// the hike holds later. `nil` until a search has a plan.
    @ObservationIgnored private var fingerprint: HikePhotoSearchPlan.Fingerprint?
    /// What the hiker has left out of the offers replaced so far, which the
    /// next one leaves out too — see ``searchAgainIfObsolete(in:)``.
    @ObservationIgnored private var unticked: Set<String> = []
    /// The one import in flight, held so the sheet can cancel it — see
    /// ``runImport(into:store:)``.
    @ObservationIgnored private var importTask: Task<Int, Never>?

    /// - Parameter work: Replaced only by a suite that watches where the
    ///   search's work runs.
    init(
        reader: some PhotoLibraryReading = PhotosLibraryReader(),
        work: PhotoDiscoveryWork = .standard
    ) {
        self.reader = reader
        self.work = work
    }

    var selectedCount: Int { selection.count }

    /// Whether there is more of the library the user could let this app see.
    var canSelectMorePhotos: Bool { libraryAccess == .limited }

    var canImport: Bool {
        guard case .results = phase else { return false }
        return !selection.isEmpty
    }

    private var isImporting: Bool {
        guard case .importing = phase else { return false }
        return true
    }

    /// Looks through the library for photographs taken during `hike`.
    ///
    /// Safe to call again on the same controller: a second run re-reads the
    /// hike's imported identifiers, so anything already attached is skipped
    /// rather than offered twice — and a second run started before the first
    /// has finished is the only one that writes, so a search overtaken while
    /// it was matching drops its answer rather than replacing the newer one.
    ///
    /// What it writes describes the hike as it stands: a search whose plan
    /// the hike has moved on from by the end starts again from the new one.
    func search(in hike: Hike) async {
        unticked = []
        await runSearch(in: hike)
    }

    private func runSearch(in hike: Hike) async {
        searchGeneration += 1
        let generation = searchGeneration
        // This controller outlives its sheet. Withdraw its previous results
        // before indexing suspends, so reopening cannot import an old
        // selection while the new search is being prepared.
        phase = .searching
        matches = []
        selection = []
        importFailed = false
        fingerprint = nil
        // No plan is a hike the store did not hand back, which this context
        // can still hold. It has gone as a detached one has, so nothing is
        // written — see ``PhotoDiscoveryWork/plan(for:)``.
        guard let plan = await work.plan(for: HikePhotoSearchPlan.SourceRead(hike)),
              isCurrent(generation), hike.isAttached
        else { return }
        fingerprint = plan.fingerprint
        guard !plan.isEmpty else {
            phase = .unsupported
            return
        }
        let access = await reader.requestAccess()
        guard isCurrent(generation) else { return }
        libraryAccess = access
        guard access.allowsReading else {
            phase = access == .restricted ? .accessRestricted : .accessDenied
            return
        }

        let assets = await libraryAssets(in: plan.searchWindows)
        guard isCurrent(generation), hike.isAttached else { return }

        // Asked again after the fetch, not only before it. The fetch is a
        // cross-process query that can take seconds, and what a library the
        // app may no longer read returns is an empty array — which would land
        // in `empty` and tell the user their walk had no photographs, when
        // what actually happened is that permission went away underneath the
        // question. A revocation has to end the flow where a refusal does.
        let remaining = reader.currentAccess()
        libraryAccess = remaining
        guard remaining.allowsReading else {
            phase = remaining == .restricted ? .accessRestricted : .accessDenied
            return
        }

        let found = await work.matches(
            in: plan,
            of: assets,
            alreadyImported: hike.importedPhotoAssetIdentifiers
        )
        guard isCurrent(generation), hike.isAttached else { return }

        // Last, so every wait above is behind it: see this file's header. A
        // save after this read is the watch's to hear.
        let current = await work.fingerprint(of: HikePhotoSearchPlan.SourceRead(hike))
        guard isCurrent(generation), hike.isAttached else { return }
        guard current == plan.fingerprint else {
            await runSearch(in: hike)
            return
        }
        matches = found
        selection = Set(found.map(\.id)).subtracting(unticked)
        phase = found.isEmpty ? .empty : .results
    }

    /// Whether the search numbered `generation` may still write: it has not
    /// been cancelled, and no newer search has started since.
    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == searchGeneration
    }

    /// Keeps the offer true to `hike` for as long as the calling task runs,
    /// by looking again at every save of its store.
    ///
    /// The sheet starts this when its first search has ended. Nothing falls
    /// between the two: ``StoreSaves/changes`` has an element at once, so a
    /// save since that search's last look is heard here.
    ///
    /// A save is the store's own notification rather than a move of
    /// ``Hike/lineRevision``, because that is the one a line received from
    /// another device posts as well, and a walk: see `StoreSaves.swift`. Any
    /// save of the store wakes this, and costs one read off the main actor
    /// while the sheet is up. Asking history which rows were saved would
    /// spare that read, and could not name a walk it had never seen.
    func followSaves(of hike: Hike) async {
        guard let container = hike.modelContext?.container else { return }
        let saves = StoreSaves(in: container, store: hike.persistentModelID.storeIdentifier)
        for await _ in saves.changes {
            await searchAgainIfObsolete(in: hike)
        }
    }

    /// Asks again if the hike no longer holds what the offer was built from.
    ///
    /// Nothing while an import runs, which looks for itself before each photo
    /// and comes back here when it ends, and nothing while a search has no
    /// plan yet, which looks before it writes.
    ///
    /// The hiker's review carries over: results arrive ticked, but one of
    /// these is a review already under way rather than a new one, and a pin
    /// that moved is no reason to put back a photo they took out.
    private func searchAgainIfObsolete(in hike: Hike) async {
        guard !isImporting, hike.isAttached else { return }
        let current = await work.fingerprint(of: HikePhotoSearchPlan.SourceRead(hike))
        guard !Task.isCancelled, !isImporting, hike.isAttached, let fingerprint, current != fingerprint
        else { return }
        unticked = unticked.union(matches.map(\.id)).subtracting(selection)
        await runSearch(in: hike)
    }

    /// Everything the library holds in any of `windows`, each asset once.
    ///
    /// One fetch per window rather than one across the lot. The windows are
    /// already merged, so what is left between two of them is genuinely
    /// unrelated time — a trail imported from a track recorded years ago and
    /// walked this morning has two, and the span between them is a query for
    /// every photograph the user owns.
    ///
    /// Deduplicated by the library's own identifier rather than by the
    /// moment, which is the same reason ``HikePhoto/assetLocalIdentifier``
    /// exists: two frames of a burst share a second. The windows are disjoint
    /// once merged, so nothing should arrive twice — but what comes back here
    /// is whatever a reader answered, and one photograph offered as two rows
    /// is a photograph the user would import twice.
    private func libraryAssets(
        in windows: [ClosedRange<Date>]
    ) async -> [PhotoLibraryAsset] {
        var found: [PhotoLibraryAsset] = []
        var seen: Set<String> = []
        for window in windows {
            guard !Task.isCancelled else { return found }
            for asset in await reader.assets(takenIn: window)
            where seen.insert(asset.localIdentifier).inserted {
                found.append(asset)
            }
        }
        return found
    }

    /// Hands the user the system's own picker for the shared subset, then
    /// searches again with whatever it left the app able to see.
    ///
    /// The way out of the one dead end this feature can create. Under
    /// ``PhotoLibraryAccess/limited`` a search sees only what was shared, so a
    /// walk whose photographs were not among them finds nothing — and nothing
    /// else in this app could change that answer.
    ///
    /// The search is re-run whether or not the picker reports a change. It
    /// reports additions only, while the same picker can take a photograph's
    /// access away, so its answer cannot stand in for "is anything different
    /// now"; the fetch is narrowed to the walk's own window and is cheap
    /// enough to be the thing that decides.
    func selectMorePhotos(
        in hike: Hike,
        from presenter: LimitedLibraryPresenter
    ) async {
        guard canSelectMorePhotos else { return }
        await reader.presentLimitedLibraryPicker(from: presenter)
        guard !Task.isCancelled, hike.isAttached else { return }
        await search(in: hike)
    }

    func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func selectAll() { selection = Set(matches.map(\.id)) }

    func deselectAll() { selection = [] }

    /// The review grid's picture for one match.
    func thumbnail(for match: LibraryPhotoMatch) async -> LoadedPhotoImage? {
        await reader.thumbnail(
            for: match.asset.localIdentifier,
            maxPixelSize: Self.thumbnailPixelSize
        )
    }

    /// Runs an import as *the* import, so the sheet that started it can stop
    /// it on the way out.
    ///
    /// Held here rather than in the button's own `Task` for the reason
    /// ``PhotoCaptureController/runLibraryImport(_:)`` holds the other one: a
    /// `Task` started in a button action is owned by nobody, and a view going
    /// away does not touch it. The Add button's did exactly that — dismissing
    /// the sheet mid-import left it reading full-size assets, possibly down
    /// from iCloud, for a screen that no longer existed, and still writing
    /// ``phase`` and ``matches`` that nothing was drawing.
    ///
    /// Which is worse than wasted work, because this controller outlives its
    /// sheet — the top of this file says for how long. Reopening the sheet
    /// hands the same controller to a fresh ``search(in:)``, so an abandoned
    /// import was free to land its tail on top of that search — resetting a
    /// phase mid-search, and clearing matches the new search had just found.
    ///
    /// - Returns: How many landed, or `nil` once the import has been stopped
    ///   by ``cancelImport()`` or ``reset()``, or overtaken by a newer one.
    ///   A stopped import still finishes the copy it was part-way through,
    ///   and returns after it, by which time its sheet may have been opened
    ///   again. The Add button closes its sheet on this count, and its
    ///   dismiss action, read in the presentation that has gone, writes the
    ///   binding the reopened one is shown by: a count would close that one.
    @discardableResult func runImport(
        into hike: Hike,
        store: HikePhotoStore = .shared
    ) async -> Int? {
        importTask?.cancel()
        let task = Task { await importSelected(into: hike, store: store) }
        importTask = task
        let landed = await task.value
        guard importTask == task else { return nil }
        importTask = nil
        return landed
    }

    /// Stops an import whose sheet has gone away.
    ///
    /// What already landed stays: each photo is written through
    /// ``HikePhotoImport``, which puts the app's own copy on disk before
    /// anything else, so a picture that made it is a picture the user has.
    /// Everything the user did not wait for is still in their library,
    /// untouched, and a reopened sheet offers it again.
    func cancelImport() {
        importTask?.cancel()
        importTask = nil
    }

    /// Puts this controller back where a new one starts, for the sheet the
    /// section is about to present.
    ///
    /// Called by ``HikePhotoSection``'s button, in the tap that presents the
    /// sheet. The sheet's first body pass reads ``phase`` and ``matches``
    /// before its `.task` has started a search, and until this the search was
    /// the only thing that withdrew them, so a reopened sheet was first built
    /// as the last one was closed: the old grid and its Add button after
    /// *Done*, the empty state after an import that took everything, or the
    /// count of an import it was closed part-way through.
    ///
    /// Nothing the last presentation started may write here after this, or
    /// close the sheet this tap presents. A search started by *Select More
    /// Photos* runs in that button's own `Task`, which closing the sheet does
    /// not cancel, so it is overtaken here as a newer search would overtake
    /// it. The import is cancelled when the sheet goes, and again here, so
    /// that a clean first pass does not depend on the sheet's `onDisappear`
    /// having come before the tap, and once stopped it hands the Add button
    /// no count to close a sheet on — see ``runImport(into:store:)``.
    func reset() {
        searchGeneration += 1
        cancelImport()
        phase = .idle
        libraryAccess = nil
        matches = []
        selection = []
        importFailed = false
        fingerprint = nil
        unticked = []
    }

    /// Copies the chosen photos into `hike`, and returns how many landed.
    ///
    /// Sequential rather than concurrent, deliberately. Each import reads a
    /// full-size asset — possibly down from iCloud — decodes it to work out
    /// what it is, and writes it twice; a dozen of those in parallel is a
    /// memory spike on the one device this runs on, for a wait the user is
    /// already watching a counter for.
    ///
    /// Reached through ``runImport(into:store:)`` in the app, which is what
    /// makes the cancellation checks below something more than decoration.
    ///
    /// Stops at the first photograph whose pin the hike has moved on from,
    /// and asks again for whatever did not land: see this file's header.
    @discardableResult func importSelected(
        into hike: Hike,
        store: HikePhotoStore = .shared
    ) async -> Int {
        let chosen = matches.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return 0 }
        importFailed = false
        phase = .importing(completed: 0, total: chosen.count)
        // Held here, because what these pins rest on is the plan that placed
        // them. ``reset()`` can clear the property under a stopped import,
        // and the copy it is part-way through still lands.
        let offered = fingerprint

        var landed: Set<String> = []
        for match in chosen {
            guard !Task.isCancelled else { break }
            // The user can pop back and delete the hike while this runs; there
            // is nothing left to attach the rest of the selection to.
            guard hike.isAttached else { break }
            let attachment = await attach(match, restingOn: offered, to: hike, store: store)
            if attachment == .stored { landed.insert(match.id) }
            // Asked again on this side of the copy, because everything below
            // writes state a sheet draws — and a cancelled import has no sheet
            // left to draw it. Whatever replaced it owns those properties now,
            // and a stale counter or a stale failure notice landing on top of
            // a fresh search is the one thing cancelling has to prevent.
            guard !Task.isCancelled else { break }
            // The rest of the selection was placed on the same plan.
            guard attachment != .obsolete else { break }
            if attachment == .failed { importFailed = true }
            phase = .importing(completed: landed.count, total: chosen.count)
        }

        guard !Task.isCancelled else { return landed.count }
        // Exactly what landed leaves the list, so a sheet left open offers the
        // rest — including anything that failed, which is the one case where
        // trying again is the right thing to do.
        matches.removeAll { landed.contains($0.id) }
        selection = selection.subtracting(landed)
        phase = matches.isEmpty ? .empty : .results
        // Whatever stayed was placed on the plan, and while this ran the watch
        // left it to this: a line that came during the last photograph, or
        // the one that stopped the loop.
        if !matches.isEmpty { await searchAgainIfObsolete(in: hike) }
        return landed.count
    }

    /// What became of one photograph of a selection.
    private enum Attachment {
        case failed
        /// Left in the library, because its pin no longer describes the hike.
        case obsolete
        case stored
    }

    private func attach(
        _ match: LibraryPhotoMatch,
        restingOn offered: HikePhotoSearchPlan.Fingerprint?,
        to hike: Hike,
        store: HikePhotoStore
    ) async -> Attachment {
        guard let data = await reader.imageData(
            for: match.asset.localIdentifier
        ) else { return .failed }
        var obsolete = false
        let photo = await HikePhotoImport.add(
            data,
            to: hike,
            coordinate: match.coordinate,
            // Never mirrored: the picture is already in the library — that is
            // where it came from — and a copy would leave the user with two.
            savesToPhotoLibrary: false,
            // The moment it was taken, not the moment it was found. This is
            // what puts an imported photo in its place in the gallery strip,
            // which is ordered by ``HikePhoto/capturedAt``.
            capturedAt: match.asset.createdAt,
            assetLocalIdentifier: match.asset.localIdentifier,
            matchEvidence: match.evidence,
            // Asked once the bytes are on disk rather than before they are
            // loaded: loading them can be a download, writing them is a wait
            // too, and nothing after this answer is one.
            pinStillHolds: {
                guard hike.isAttached else { return true }
                obsolete = await work.fingerprint(of: HikePhotoSearchPlan.SourceRead(hike)) != offered
                return !obsolete
            },
            store: store
        )
        if obsolete { return .obsolete }
        return photo == nil ? .failed : .stored
    }
}
