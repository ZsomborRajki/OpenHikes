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
//  same controller, with whatever the last one left in it. Only a new section
//  makes a new one: opening the hike again, flipping its screen to *History*
//  and back, or a turn or an iPhone Duo opening or closing that moves the
//  screen between the sheet and the side panel — see *The map screen* in the
//  repository instructions.
//
//  None of what the last presentation left is meant to reach the next one.
//  Each search withdraws the previous results before it first suspends, and
//  the sheet cancels a running import as it goes, because an import left
//  running would write into the state the next search is filling — see
//  ``search(in:)`` and ``runImport(into:store:)``. The withdrawal comes after
//  a reopened sheet's first body pass, though: the search is started by the
//  `.task` that pass attaches, so that pass is built from whatever the last
//  presentation left.
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
//  ``PhotoDiscoveryWork``. Here the hike is only named, before the hop — see
//  ``HikePhotoSearchPlan/SourceRead`` — and only the newest search writes
//  what comes back: the sheet starts one per presentation, and the picker for
//  the shared subset starts another, so an older one still matching must not
//  land its answer on top of the newer one's.
//

import Foundation
import Observation
import OpenHikesData
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

    /// Looks through the library for photographs taken during `hike`.
    ///
    /// Safe to call again on the same controller: a second run re-reads the
    /// hike's imported identifiers, so anything already attached is skipped
    /// rather than offered twice — and a second run started before the first
    /// has finished is the only one that writes, so a search overtaken while
    /// it was matching drops its answer rather than replacing the newer one.
    func search(in hike: Hike) async {
        searchGeneration += 1
        let generation = searchGeneration
        // This controller outlives its sheet. Withdraw its previous results
        // before indexing suspends, so reopening cannot import an old
        // selection while the new search is being prepared.
        phase = .searching
        matches = []
        selection = []
        importFailed = false
        let plan = await work.plan(for: HikePhotoSearchPlan.SourceRead(hike))
        guard isCurrent(generation), hike.isAttached else { return }
        guard !plan.isEmpty else {
            phase = .unsupported
            return
        }
        let access = await reader.requestAccess()
        guard generation == searchGeneration else { return }
        libraryAccess = access
        guard access.allowsReading else {
            phase = access == .restricted ? .accessRestricted : .accessDenied
            return
        }
        guard !Task.isCancelled else { return }

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
        matches = found
        selection = Set(found.map(\.id))
        phase = found.isEmpty ? .empty : .results
    }

    /// Whether the search numbered `generation` may still write: it has not
    /// been cancelled, and no newer search has started since.
    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == searchGeneration
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
    @discardableResult func runImport(
        into hike: Hike,
        store: HikePhotoStore = .shared
    ) async -> Int {
        importTask?.cancel()
        let task = Task { await importSelected(into: hike, store: store) }
        importTask = task
        let landed = await task.value
        if importTask == task { importTask = nil }
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
    @discardableResult func importSelected(
        into hike: Hike,
        store: HikePhotoStore = .shared
    ) async -> Int {
        let chosen = matches.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return 0 }
        importFailed = false
        phase = .importing(completed: 0, total: chosen.count)

        var landed: Set<String> = []
        for match in chosen {
            guard !Task.isCancelled else { break }
            // The user can pop back and delete the hike while this runs; there
            // is nothing left to attach the rest of the selection to.
            guard hike.isAttached else { break }
            let stored = await attach(match, to: hike, store: store)
            if stored { landed.insert(match.id) }
            // Asked again on this side of the copy, because everything below
            // writes state a sheet draws — and a cancelled import has no sheet
            // left to draw it. Whatever replaced it owns those properties now,
            // and a stale counter or a stale failure notice landing on top of
            // a fresh search is the one thing cancelling has to prevent.
            guard !Task.isCancelled else { break }
            if !stored { importFailed = true }
            phase = .importing(completed: landed.count, total: chosen.count)
        }

        guard !Task.isCancelled else { return landed.count }
        // Exactly what landed leaves the list, so a sheet left open offers the
        // rest — including anything that failed, which is the one case where
        // trying again is the right thing to do.
        matches.removeAll { landed.contains($0.id) }
        selection = selection.subtracting(landed)
        phase = matches.isEmpty ? .empty : .results
        return landed.count
    }

    private func attach(
        _ match: LibraryPhotoMatch,
        to hike: Hike,
        store: HikePhotoStore
    ) async -> Bool {
        guard let data = await reader.imageData(
            for: match.asset.localIdentifier
        ) else { return false }
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
            store: store
        )
        return photo != nil
    }
}
