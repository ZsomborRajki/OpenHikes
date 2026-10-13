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
//  be writing, and it can only keep what it knows the name of. What Commons *said* about the files is kept, for thirty days —
//  see ``CommonsPhotoStore``.
//

import Foundation
import Observation
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
        launch = Self.freshDirectory(in: root)
        directory = Self.freshDirectory(in: launch)
        // One with nowhere to ask writes nothing, and every suite's browser
        // is one of those, so it leaves the directory to the one that does.
        if source != nil { Self.sweep(root, keeping: launch) }
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
        let target = Self.freshDirectory(in: launch)
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
                Self.remove(target)
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
        Self.remove(directory)
        if let retired { Self.remove(retired) }
        retired = nil
        directory = Self.freshDirectory(in: launch)
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
        if let retired { Self.remove(retired) }
        retired = directory
        directory = target
        if photos != found { photos = found }
    }

    private static func freshDirectory(in root: URL) -> URL {
        root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Whatever an earlier launch left under `root`, except `current`.
    private static func sweep(_ root: URL, keeping current: URL) {
        let kept = current.lastPathComponent
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            let left = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in left where url.lastPathComponent != kept {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// Off the main actor, for the reason ``TrailDraftPhotos`` gives.
    nonisolated private static func remove(_ url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
