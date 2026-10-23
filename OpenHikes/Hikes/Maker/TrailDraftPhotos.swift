//
//  TrailDraftPhotos.swift
//  OpenHikes
//
//  Wikimedia Commons photographs of the area the maker's map is showing.
//
//  A planning tool is better for pictures: whether the lake is worth the
//  detour and which side of the ridge the view is on are questions a
//  photograph answers and a pin does not. Commons already has geotagged,
//  openly licensed ones across most hiking country, and the curated preview
//  shows them along a route — see ``CommonsPhoto``. Here they are shown over
//  an *area*, because there is no route yet, and each one is a place a stop
//  can go: its card has *Add Stop* at the camera's own position.
//
//  ## Asked by the pill that already asks
//
//  *Search this area* is the maker's one way to ask anything about the ground,
//  and a tap that asked Overpass for the huts and Commons for the photographs
//  is one question to the hiker. So the *Photos* chip under it decides whether
//  that tap asks Commons too — see ``TrailPlaceFilter/photosShown`` — and
//  nothing here runs on a pan, an open or a timer. A second tap over another
//  valley adds that valley's photographs to the ones already on the map, and
//  a tap over the same valley again asks for the next ones along rather than
//  the same — see ``WikimediaCommonsSource``.
//
//  ## Not part of the drawing
//
//  Held beside it like ``TrailPointFinder``: nothing here is written down with
//  the draft or restored with it, and a relaunch starts without them — the
//  pill brings them back. The files are in a directory of this object's own
//  under the temporary directory, deleted when the drawing is thrown away and
//  swept at the next launch whatever happened, since none of them can be
//  wanted by then.
//
//  ## Kept by a save, credited
//
//  The user's call of 2026-10-12: Save copies the photographs the finished
//  line passes into the hike, exactly as *Add to My Hikes* copies a curated
//  route's — credited, under the licence each came with, pinned onto the line,
//  and never offered for publishing, which ``HikePhoto/isOwn`` refuses for any
//  photograph with a licence. *Passes* is the rule the picked photographs
//  follow (``CommonsTrailPhotos/corridorMeters``), for the reason a save keeps
//  only the places the line touches: a search puts everything near the drawing
//  on the map, and the summit across the valley is not a picture of this walk.
//  See ``TrailDraftPhotoHandOff``, and ``TrailDraftPhotoCopy`` for what
//  happens to the ones the copy misses.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesData
import os
import SwiftData

@MainActor
@Observable
final class TrailDraftPhotos {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    /// What every search so far found, nearest the middle of its area first
    /// and in the order the searches landed.
    private(set) var photos: [CommonsPhoto] = []

    /// Whether a search is out. Spins the pill alongside the place search.
    private(set) var isSearching = false

    /// Where a search asks, or `nil` for a launch that must not — a preview,
    /// and every test launch that did not name a scenario. See
    /// ``OpenHikesModel/makeTrailPhotoSource()``.
    @ObservationIgnored let source: (any CommonsPhotoSourcing)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Where every launch's photographs go, one directory per drawing under
    /// it — see the file header for why it is swept whole.
    @ObservationIgnored private let root: URL
    /// The directory this drawing's photographs are downloaded into.
    @ObservationIgnored private(set) var directory: URL
    /// Where a save's photographs go once they are handed over, and what the
    /// copy missed. Held here because this outlives the drawing, which a save
    /// throws away before the copy has finished.
    @ObservationIgnored let photoCopy: TrailDraftPhotoCopy

    /// - Parameter root: Where the directories go. A suite passes one of its
    ///   own, so two suites never sweep each other's.
    init(
        source: (any CommonsPhotoSourcing)? = nil,
        root: URL = FileManager.default.temporaryDirectory
            .appending(path: "TrailDraftPhotos", directoryHint: .isDirectory),
        photoCopy: TrailDraftPhotoCopy = TrailDraftPhotoCopy()
    ) {
        self.source = source
        self.root = root
        self.photoCopy = photoCopy
        directory = StagedFiles.freshDirectory(in: root)
        StagedFiles.sweep(root, keeping: directory)
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Whether this launch can ask at all.
    var isAvailable: Bool { source != nil }

    /// The photograph whose downloaded copy is at `fileURL`, which is how the
    /// map and the card name one — see ``TrailDraftSelection/photo(_:)``.
    func photo(at fileURL: URL) -> CommonsPhoto? {
        photos.first { $0.fileURL == fileURL }
    }

    /// Asks for the photographs taken in `area`. Refused while one is out,
    /// like the place search beside it. Answers whether it asked.
    @discardableResult func search(in area: CommunitySearchArea) -> Bool {
        guard let source, !isSearching else { return false }
        isSearching = true
        let target = directory
        let shown = Set(photos.map(\.credit.license.sourceURL))
        task = Task { [weak self] in
            let found: [CommonsPhoto]
            do {
                found = try await source.photos(in: area, avoiding: shown, downloadingInto: target)
            } catch {
                if !(error is CancellationError) {
                    Self.logger.info(
                        "A photo search found nothing: \(error.localizedDescription, privacy: .public)"
                    )
                }
                found = []
            }
            guard let self, !Task.isCancelled else { return }
            receive(found, into: target)
        }
        return true
    }

    /// Drops a search in flight and keeps what is already found — what the
    /// maker closing, or the places switch hiding everything, does.
    func cancelSearch() {
        task?.cancel()
        task = nil
        if isSearching { isSearching = false }
    }

    /// Forgets every photograph and deletes their files — the *Photos* chip
    /// turned off, and the drawing thrown away.
    func clear() {
        cancelSearch()
        if !photos.isEmpty { photos = [] }
        StagedFiles.remove(directory)
        directory = StagedFiles.freshDirectory(in: root)
    }

    /// Takes a photograph found somewhere else onto this drawing's map — the
    /// *Community* tab's, whose *Plan a Trail Here* made it the destination.
    /// See ``TrailDraftController/plan(to:)``.
    ///
    /// The file is copied into this drawing's directory, off the main actor,
    /// so it outlives the tab's next search, which deletes the one it came
    /// from. Nothing happens for a photograph already here (by its Commons
    /// page), or when the copy fails — the destination is still set, and the
    /// picture is only missing from the map.
    @discardableResult func adopt(_ photo: CommonsPhoto) -> Task<Void, Never> {
        let page = photo.credit.license.sourceURL
        let target = directory
        return Task { [weak self] in
            guard self?.photos.contains(where: { $0.credit.license.sourceURL == page }) == false,
                  let copy = await Self.copy(photo.fileURL, into: target),
                  let self,
                  // Cleared while the copy was being made: the chip went
                  // off, or the drawing was thrown away.
                  target == directory,
                  !photos.contains(where: { $0.credit.license.sourceURL == page })
            else { return }
            var adopted = photo
            adopted.fileURL = copy
            photos.append(adopted)
        }
    }

    /// Hands the photographs the saved line passes to whatever copies them
    /// into the hike, and forgets them here without deleting their files —
    /// the hand-off owns those now. `nil` when the line passes none.
    ///
    /// Taken before the drawing is discarded, which is what would otherwise
    /// delete the files mid-copy.
    func handOff(along route: [RouteCoordinate]) -> TrailDraftPhotoHandOff? {
        cancelSearch()
        let kept = Self.onTrail(photos, along: route)
        guard !kept.isEmpty else { return nil }
        let handOff = TrailDraftPhotoHandOff(photos: kept, directory: directory)
        photos = []
        directory = StagedFiles.freshDirectory(in: root)
        return handOff
    }

    /// The photographs whose camera stood within
    /// ``CommonsTrailPhotos/corridorMeters`` of `route`, each pinned onto the
    /// line, in walking order — how a curated route's are placed, so a
    /// photograph saved from either reads the same on the hike.
    nonisolated static func onTrail(_ photos: [CommonsPhoto], along route: [RouteCoordinate]) -> [CommonsPhoto] {
        guard route.count > 1 else { return [] }
        // Each photograph stands in by its position in the list, which is the
        // one identity the placement needs: it only reads it back.
        let candidates = photos.indices.compactMap { index in
            photos[index].pin.coordinate.map { coordinate in
                CommonsPhotoCandidate(pageID: index, latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        }
        return CommonsTrailPhotos.placed(candidates, on: RouteProfile(route: route))
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
            .map { placed in
                var photo = photos[placed.pageID]
                photo.pin = CommunityPhotoPin(capturedAt: photo.pin.capturedAt, coordinate: placed.coordinate)
                return photo
            }
    }

    private func receive(_ found: [CommonsPhoto], into target: URL) {
        isSearching = false
        // Landed in a directory that has since been cleared — the chip went
        // off and on again while the request was out.
        guard target == directory else { return }
        let held = Set(photos.map(\.fileURL))
        let added = found.filter { !held.contains($0.fileURL) }
        guard !added.isEmpty else { return }
        photos += added
    }

    /// A copy of `file` in `directory`, or `nil` when it could not be made.
    @concurrent
    nonisolated private static func copy(_ file: URL, into directory: URL) async -> URL? {
        let manager = FileManager.default
        let copy = directory.appending(path: "adopted-\(UUID().uuidString)-\(file.lastPathComponent)")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: copy)
            return copy
        } catch {
            return nil
        }
    }
}

/// The photographs a saved trail passes, on their way into the hike.
///
/// The ``CommunityImport`` half that applies here, written again rather than
/// reached into: that one is about a listing and its three sets, and this is
/// one set with no listing. What each copy is stamped with is the same and is
/// owed by the licence rather than chosen — the author on
/// ``HikePhoto/importedAuthorName``, the licence and its links on
/// ``HikePhoto/license`` (which alone keeps it from ever being published), and
/// ``PhotoMatchEvidence/place`` for a pin worked out from the camera.
nonisolated struct TrailDraftPhotoHandOff: Sendable {
    let photos: [CommonsPhoto]
    /// Where their files are, deleted once they are copied or let go.
    let directory: URL

    /// Copies each photograph onto `hike` that it does not already hold.
    /// Answers the ones the store or the save refused, as a hand-off of their
    /// own whose files are still on disk for another try — see
    /// ``TrailDraftPhotoCopy`` — or `nil` when nothing is left to copy, which
    /// is when the downloaded files are deleted.
    ///
    /// *Already holds* is by Commons page, so an edited trail saved again does
    /// not gain a second copy of a picture its first save kept, and a retry
    /// copies only what the first attempt missed. An unreadable source is
    /// handed back too: a read failure must be reported, and a later attempt
    /// may be able to read it.
    @MainActor
    func attach(
        to hike: Hike,
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter(),
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) async -> Self? {
        var missed: [CommonsPhoto] = []
        for photo in photos {
            // Re-checked every picture: the hike can be deleted while a dozen
            // are being copied, and writing to a detached row keeps nothing.
            guard hike.isAttached,
                  !hike.photos.contains(where: { $0.license?.sourceURL == photo.credit.license.sourceURL })
            else { continue }
            guard let data = await Self.read(photo.fileURL) else {
                missed.append(photo)
                continue
            }
            guard hike.isAttached else { continue }
            let stored = await HikePhotoImport.add(
                data,
                to: hike,
                coordinate: photo.pin.coordinate,
                // Never the hiker's setting: it is somebody else's picture.
                savesToPhotoLibrary: false,
                capturedAt: photo.pin.capturedAt,
                matchEvidence: .place,
                importedAuthorName: photo.credit.author,
                license: photo.credit.license,
                store: store,
                libraryWriter: libraryWriter,
                save: save
            )
            if stored == nil { missed.append(photo) }
        }
        // A hike deleted part way has nowhere for a retry to put anything.
        guard hike.isAttached, !missed.isEmpty else {
            discard()
            return nil
        }
        return Self(photos: missed, directory: directory)
    }

    /// Deletes the downloaded files, off the main actor: what a hand-off
    /// comes to once nothing is left to copy, or once the hiker lets the
    /// missing photographs go.
    func discard() {
        let copied = directory
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: copied) }
    }

    /// Reads a downloaded file off the main actor — see
    /// ``CommunityImport``'s own `readFile(at:)`.
    @concurrent
    private static func read(_ url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
