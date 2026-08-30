//
//  PhotoDiscoveryController.swift
//  OpenHikes
//
//  The state behind "Find Photos of This Hike": ask, search, offer, import.
//
//  A reference type observed by one sheet, for the ordinary reason — the
//  search is a `Task` that outlives a view body, and the selection has to
//  survive the grid being rebuilt as thumbnails land. Nothing else in the app
//  observes it, and it is created per presentation rather than owned by the
//  model: there is no state here worth keeping once the sheet is gone.
//
//  Three things are worth stating about the order it does its work in.
//
//  Permission is asked for after the timeline is built, not before. A hike
//  whose route carries no timestamps has nothing to match against, and
//  prompting for access to somebody's photo library in order to then tell them
//  the feature cannot work is the worst possible sequence.
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

import Foundation
import Observation
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
        /// The route carries no timestamps, so there is no clock to look a
        /// photograph up against. Distinct from ``empty``, which means the
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
    /// The one import in flight, held so the sheet can cancel it — see
    /// ``runImport(into:store:)``.
    @ObservationIgnored private var importTask: Task<Int, Never>?

    init(reader: some PhotoLibraryReading = PhotosLibraryReader()) {
        self.reader = reader
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
    /// rather than offered twice.
    func search(in hike: Hike) async {
        guard let timeline = hike.photoTimeline else {
            phase = .unsupported
            return
        }
        phase = .searching
        matches = []
        selection = []
        importFailed = false

        let access = await reader.requestAccess()
        libraryAccess = access
        guard access.allowsReading else {
            phase = access == .restricted ? .accessRestricted : .accessDenied
            return
        }
        guard !Task.isCancelled else { return }

        let assets = await reader.assets(takenIn: timeline.searchWindow)
        guard !Task.isCancelled, hike.isAttached else { return }

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

        let found = LibraryPhotoMatcher.matches(
            assets: assets,
            timeline: timeline,
            route: hike.route,
            alreadyImported: hike.importedPhotoAssetIdentifiers
        )
        matches = found
        selection = Set(found.map(\.id))
        phase = found.isEmpty ? .empty : .results
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
    /// sheet: it is created once per hike screen so that reopening the sheet
    /// doesn't lose what a scan already found. An abandoned import was
    /// therefore free to land its tail on top of the fresh ``search(in:)``
    /// that reopening starts — resetting a phase mid-search, and clearing
    /// matches the new search had just found.
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
