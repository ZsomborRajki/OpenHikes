//
//  CommunityCommonsPhotos.swift
//  OpenHikes
//
//  Wikimedia Commons photographs of the area the *Community* tab last asked
//  about.
//
//  The tab answers *where could I walk around here* with published hikes and
//  OpenStreetMap trails. A photograph is the other half of that question —
//  whether the lake is worth the drive and which side of the ridge the view is
//  on — and Commons has geotagged, openly licensed ones across most hiking
//  country. The trail maker already shows them for the same reason; see
//  ``TrailDraftPhotos``. Here a photo pin opens a screen of its own, and that
//  screen's *Plan a Trail Here* opens the maker with the camera's position as
//  the destination. See ``CommonsPhotoView``.
//
//  ## Asked by the question the tab already asks
//
//  Every question the list asks a hiker to confirm — opening the tab, *Search
//  this area*, *Try Again* — asks Commons about the part of the same area the
//  map is showing. That is one tap and one geosearch, never wider than ten
//  kilometres, which is as wide as a geosearch goes
//  (``CommonsTrailPhotos/maximumRadiusMeters``) — see
//  ``CommunityBrowser/photoArea(of:showing:)`` for why it is the visible part.
//  The refill after a block does not ask, because it is not a hiker asking
//  anything. Nothing runs on a pan.
//
//  **The answer replaces the last one**, as the rows do. The maker adds each
//  search to the one before because there the photographs are things to
//  build a trail from. Here they are an answer about one area, and the
//  previous valley's pictures beside this valley's rows would describe two
//  places at once.
//
//  ## One switch for both
//
//  The maker's *Photos* chip decides here too (``TrailPlaceFilter/photosShown``,
//  on by default): with it off, the tab asks Commons nothing and draws
//  nothing. Two switches for one source of pictures would be one more thing
//  to find when they first appear somewhere unwanted.
//
//  ## Not kept
//
//  Like the maker's, the downloads live in a directory under the temporary
//  directory: a fresh one per answer, the one before kept until the next
//  lands — a photograph's screen may still be reading it — and all of them
//  swept at the next launch. Every answer's directory is inside one of this
//  launch's own, because the sweep runs while the first search may already
//  be writing, and it can only keep what it knows the name of.
//
//  A screen can outlive two answers, and its photograph's file with them. So
//  it asks ``usable(_:)`` again as each lands: the same page in the newest
//  answer if it is there, and otherwise the thumbnail downloaded again into a
//  directory of its own — see ``CommonsPhotoSourcing/download(_:into:)``. What Commons *said* about the files is kept, for thirty days —
//  see ``CommonsPhotoStore``.
//

import Foundation
import Observation
import OpenHikesData
import os

@MainActor
@Observable
final class CommunityCommonsPhotos {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// What the last answered search found, nearest the middle of its area
    /// first.
    private(set) var photos: [CommonsPhoto] = []

    /// Whether a search is out.
    private(set) var isSearching = false

    /// Counts the answers that landed and the clears, each of which can
    /// delete a file an open screen is showing. What ``CommonsPhotoView``
    /// keys its ``usable(_:)`` check on.
    private(set) var revision = 0

    /// Where a search asks, or `nil` for a launch that must not — shared with
    /// the maker's, see ``OpenHikesModel/makeTrailPhotoSource()``.
    @ObservationIgnored let source: (any CommonsPhotoSourcing)?
    /// The maker's chips, whose *Photos* is this feature's switch too.
    @ObservationIgnored let filter: TrailPlaceFilter
    /// Whether the map is the maker's canvas, which draws its own photographs
    /// and a destination on one of these. Read by ``shown`` so the pins step
    /// aside while it is up — see `MapCommunityCommonsPhotos.swift`.
    @ObservationIgnored private let isHidden: () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    /// This launch's directory, which every answer's goes inside — see the
    /// file header for why.
    @ObservationIgnored private let launch: URL
    /// The directory ``photos`` are in.
    @ObservationIgnored private(set) var directory: URL
    /// The answer before, kept until the next one lands: a photograph's
    /// screen can be open while *Search this area* is tapped again, and its
    /// full-screen viewer and *Plan a Trail Here* both read the file.
    @ObservationIgnored private var retired: URL?
    /// Where photographs downloaded again by ``usable(_:)`` go: deleted by
    /// ``clear()`` and by the next launch's sweep, never by an answer
    /// landing, so a copy fetched for a screen is not lost to the next tap.
    @ObservationIgnored private var restored: URL
    /// The downloads ``usable(_:)`` has out, by Commons page, so a screen that
    /// asks twice while one is out waits for the one file — and a group's
    /// grid, whose tiles ask for several at once, waits for each.
    @ObservationIgnored private var restoring: [URL: Task<CommonsPhoto?, Never>] = [:]
    /// What those downloads brought back, by Commons page, so a tile that
    /// fetched a picture again and the screen it opens share the one copy.
    /// Its files are in ``restored`` and go with it.
    @ObservationIgnored private var restoredCopies: [URL: CommonsPhoto] = [:]

    /// - Parameters:
    ///   - isHidden: Observed through whatever it reads, so the map hears
    ///     about the maker opening without this type knowing it exists.
    ///   - root: Where the directories go. A suite passes one of its own, so
    ///     two suites never sweep each other's.
    init(
        source: (any CommonsPhotoSourcing)? = nil,
        filter: TrailPlaceFilter = TrailPlaceFilter(defaults: nil),
        isHidden: @escaping () -> Bool = { false },
        root: URL = FileManager.default.temporaryDirectory
            .appending(path: "CommunityCommonsPhotos", directoryHint: .isDirectory)
    ) {
        self.source = source
        self.filter = filter
        self.isHidden = isHidden
        launch = StagedFiles.freshDirectory(in: root)
        directory = StagedFiles.freshDirectory(in: launch)
        restored = StagedFiles.freshDirectory(in: launch)
        // One with nowhere to ask writes nothing, and every suite's browser
        // is one of those, so it leaves the directory to the one that does.
        if source != nil { StagedFiles.sweep(root, keeping: launch) }
    }

    nonisolated deinit { /* intentionally empty */ }

    /// What the map draws: the photographs, while the *Photos* chip is on and
    /// the maker is not up.
    var shown: [CommonsPhoto] {
        filter.photosShown && !isHidden() ? photos : []
    }

    /// The photograph whose downloaded copy is at `fileURL`.
    func photo(at fileURL: URL) -> CommonsPhoto? {
        photos.first { $0.fileURL == fileURL }
    }

    /// Asks what was photographed in `area`, superseding a search still out.
    ///
    /// With the *Photos* chip off this asks nothing and forgets what was
    /// found, because a chip turned off since the last search is a hiker who
    /// no longer wants them.
    func search(in area: CommunitySearchArea) {
        guard let source else { return }
        guard filter.photosShown else {
            clear()
            return
        }
        task?.cancel()
        isSearching = true
        // A directory per search, so a superseded one still writing cannot
        // put a file beside the answer that replaced it.
        let target = StagedFiles.freshDirectory(in: launch)
        task = Task { [weak self] in
            let found: [CommonsPhoto]
            do {
                found = try await source.photos(in: area, avoiding: [], downloadingInto: target)
            } catch {
                if !(error is CancellationError) {
                    Self.logger.info(
                        "An area's photo search found nothing: \(error.localizedDescription, privacy: .public)"
                    )
                }
                found = []
            }
            guard let self, !Task.isCancelled else {
                StagedFiles.remove(target)
                return
            }
            receive(found, in: target)
        }
    }

    /// Forgets every photograph and deletes their files.
    func clear() {
        task?.cancel()
        task = nil
        if isSearching { isSearching = false }
        if !photos.isEmpty { photos = [] }
        StagedFiles.remove(directory)
        if let retired { StagedFiles.remove(retired) }
        retired = nil
        directory = StagedFiles.freshDirectory(in: launch)
        for download in restoring.values { download.cancel() }
        restoring = [:]
        restoredCopies = [:]
        StagedFiles.remove(restored)
        restored = StagedFiles.freshDirectory(in: launch)
        revision += 1
    }

    /// `photo` with a file that is still on disk, or `nil` when there is
    /// none to be had.
    ///
    /// Whether its file is gone is read off which directories this holds,
    /// not off the disk: the deletes run off the main actor, so a file can
    /// still be there with its directory already let go. Then, cheapest
    /// first: the same Commons page in the newest answer, a copy already
    /// downloaded again, or the thumbnail downloaded again.
    func usable(_ photo: CommonsPhoto) async -> CommonsPhoto? {
        let folder = photo.fileURL.deletingLastPathComponent().path
        if [directory, retired, restored].contains(where: { $0?.path == folder }) { return photo }
        let page = photo.credit.license.sourceURL
        if let again = photos.first(where: { $0.credit.license.sourceURL == page }) { return again }
        if let kept = restoredCopies[page] { return kept }
        if let pending = restoring[page] { return await pending.value }
        guard let source else { return nil }
        let target = restored
        let fetching = Task { try? await source.download(photo, into: target) }
        restoring[page] = fetching
        let fetched = await fetching.value
        if restoring[page] == fetching { restoring[page] = nil }
        // Cleared while it was out: the copy went with the directory.
        guard target == restored else { return nil }
        if let fetched { restoredCopies[page] = fetched }
        return fetched
    }

    /// Waits for the search that is out, if any — the effect a suite waits on.
    func settle() async {
        await task?.value
    }

    private func receive(_ found: [CommonsPhoto], in target: URL) {
        task = nil
        isSearching = false
        // An empty answer still replaces the last one: it is an answer about
        // the new area, and the old pictures are of somewhere else.
        if let retired { StagedFiles.remove(retired) }
        retired = directory
        directory = target
        if photos != found { photos = found }
        revision += 1
    }
}
