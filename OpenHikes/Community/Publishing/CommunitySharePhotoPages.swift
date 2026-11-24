//
//  CommunitySharePhotoPages.swift
//  OpenHikes
//
//  The share gallery's pages: where each photograph stands, and which of them
//  go, worked out again only when the photographs, the hiker's exclusions or
//  the disk's answer change.
//
//  For the reason ``OrderedHikePhotos`` exists. ``CommunitySharePhotoViewer``'s
//  body runs on every page turned, because the page is its state, and each
//  pass found the page by searching the photographs for its id and rebuilt
//  ``CommunitySharePhotoChoices`` (the upload's own selection, and sets of
//  ids beside it), though a swipe moves neither. A pass now reads a
//  dictionary and the choices kept from the last pass that changed them.
//
//  The inputs are compared on every pass, which is also how a change still
//  reaches the gallery: striking a picture off writes the form's set, the
//  body re-runs for the binding, and the comparison finds a new set, so the
//  toggle, the tally and the strip under the form keep agreeing. An array or
//  a set handed in again unchanged compares its storage first, and costs no
//  walk.
//
//  A reference held in `@State`, and not `@Observable`, for the reason
//  ``OrderedHikePhotos`` gives: it caches the body's own reads, and nothing
//  should re-run because it changed.
//

import Foundation
import OpenHikesData

final class CommunitySharePhotoPages {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private var photos: [HikePhoto] = []
    private var positions: [UUID: Int] = [:]
    private var excluded: Set<UUID> = []
    private var files = CommunityPhotoFiles.unasked
    private var kept: CommunitySharePhotoChoices?
    /// How many times the positions and the choices have been worked out,
    /// for a suite to tell a rebuild from a read.
    private(set) var indexBuilds = 0
    private(set) var choiceBuilds = 0

    /// Where the photograph `id` stands among `photos`, or `nil` for none or
    /// for one not among them.
    func index(of id: UUID?, in photos: [HikePhoto]) -> Int? {
        take(photos)
        return id.flatMap { positions[$0] }
    }

    /// Which of `photos` go, as ``CommunitySharePhotoChoices`` says, built
    /// again only when one of the three things it is made from has changed.
    func choices(
        for photos: [HikePhoto],
        excluding excluded: Set<UUID>,
        files: CommunityPhotoFiles
    ) -> CommunitySharePhotoChoices {
        take(photos)
        if let kept, excluded == self.excluded, files == self.files { return kept }
        let built = CommunitySharePhotoChoices(photos: photos, excluding: excluded, files: files)
        self.excluded = excluded
        self.files = files
        kept = built
        choiceBuilds += 1
        return built
    }

    /// Indexes `photos` when they are not the ones indexed last, and drops
    /// the choices made from the old ones.
    private func take(_ photos: [HikePhoto]) {
        guard photos != self.photos || indexBuilds == 0 else { return }
        self.photos = photos
        positions = Dictionary(zip(photos.map(\.id), photos.indices)) { first, _ in first }
        kept = nil
        indexBuilds += 1
    }
}
