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

    init(reader: some PhotoLibraryReading = PhotosLibraryReader()) {
        self.reader = reader
    }

    var selectedCount: Int { selection.count }

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
        guard access.allowsReading else {
            phase = access == .restricted ? .accessRestricted : .accessDenied
            return
        }
        guard !Task.isCancelled else { return }

        let assets = await reader.assets(takenIn: timeline.searchWindow)
        guard !Task.isCancelled, hike.isAttached else { return }

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

    /// Copies the chosen photos into `hike`, and returns how many landed.
    ///
    /// Sequential rather than concurrent, deliberately. Each import reads a
    /// full-size asset — possibly down from iCloud — decodes it to work out
    /// what it is, and writes it twice; a dozen of those in parallel is a
    /// memory spike on the one device this runs on, for a wait the user is
    /// already watching a counter for.
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
            if await attach(match, to: hike, store: store) {
                landed.insert(match.id)
            } else {
                importFailed = true
            }
            phase = .importing(completed: landed.count, total: chosen.count)
        }

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
