//
//  TrailDraftPhotoCopy.swift
//  OpenHikes
//
//  The Commons photographs a drawn trail's save copies into the hike, after
//  the save rather than as part of it, and what that copy came to.
//
//  ## Missed, said, and offered again
//
//  A save does not wait for its photographs — a dozen pictures are not worth
//  holding the button for — so the hike is already on screen when the copy
//  finishes, and the maker that started it has been thrown away. A store or a
//  save that refused one of them was invisible: the hike simply had fewer
//  pictures than the map had shown along its line, and the downloaded file a
//  second try would need was deleted with the rest.
//
//  So this holds what was missed, with its files, outside the maker — on the
//  app model, which outlives every screen — and the map screen's alert says so
//  and offers *Try Again*, which copies only what is still missing, or *Skip*,
//  which deletes the files. The same bargain ``CommunityPhotoCopy`` makes on
//  the community preview, said from where the hiker now is rather than from a
//  screen that has gone. The alert is attached beside ``MapScreenAlerts``,
//  for the reason that file gives.
//

import Foundation
import Observation
import OpenHikesData
import SwiftData

@MainActor
@Observable
final class TrailDraftPhotoCopy {
    /// Photographs a save could not copy into its hike.
    struct Missed: Identifiable {
        let id = UUID()
        let hike: Hike
        /// Its name when the copy finished, so the alert never reads a hike
        /// that has been deleted under it.
        let hikeTitle: String
        let photos: TrailDraftPhotoHandOff
    }

    /// What the alert offers again, or `nil` the rest of the time.
    private(set) var missed: Missed?

    @ObservationIgnored private var pending: [Missed] = []
    @ObservationIgnored private var tail: Task<Void, Never>?
    private var isRetrying = false
    @ObservationIgnored private let store: HikePhotoStore
    @ObservationIgnored private let libraryWriter: any PhotoLibraryWriting
    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// - Parameters: The hand-off's own seams, so a suite can make the store
    ///   or the save refuse without Wikimedia or a full disk.
    init(
        store: HikePhotoStore = .shared,
        libraryWriter: any PhotoLibraryWriting = PhotoLibraryWriter(),
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.store = store
        self.libraryWriter = libraryWriter
        self.save = save
    }

    nonisolated deinit { /* intentionally empty */ }

    /// Copies `handOff` onto `hike`, and holds whatever it misses for the
    /// alert.
    ///
    /// Answers the task so a suite can wait on it; the save that calls this
    /// does not. Attempts run in order, including retries: two attempts for
    /// the same hike must not both pass its duplicate check before either
    /// has committed the photograph.
    @discardableResult func attach(_ handOff: TrailDraftPhotoHandOff, to hike: Hike) -> Task<Void, Never> {
        enqueue {
            guard let failed = await self.copy(handOff, to: hike) else { return }
            // Each trail keeps its sources until the hiker answers it. A
            // later save is not permission to abandon the earlier one's.
            self.pending.append(failed)
            self.showNext()
        }
    }

    /// Copies the missed photographs again — only those, since the hike
    /// already holds the rest. Whatever is still missed comes back as a new
    /// alert.
    @discardableResult func retry() -> Task<Void, Never>? {
        guard let missed, !isRetrying else { return nil }
        isRetrying = true
        return enqueue {
            self.missed = await self.copy(missed.photos, to: missed.hike)
            self.showNext()
            self.isRetrying = false
        }
    }

    /// Lets the missed photographs go, and their files with them.
    func skip() {
        guard let missed, !isRetrying else { return }
        self.missed = nil
        missed.photos.discard()
        showNext()
    }

    private func showNext() {
        guard missed == nil, !pending.isEmpty else { return }
        missed = pending.removeFirst()
    }

    private func copy(_ handOff: TrailDraftPhotoHandOff, to hike: Hike) async -> Missed? {
        guard let left = await handOff.attach(
            to: hike,
            store: store,
            libraryWriter: libraryWriter,
            save: save
        ) else { return nil }
        return Missed(hike: hike, hikeTitle: hike.title, photos: left)
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let next = Task {
            await previous?.value
            await operation()
        }
        tail = next
        return next
    }

    /// A retry hides the alert while keeping its sources claimed. Only the
    /// alert's own modifier reads this, so no enclosing screen observes it.
    var isShowing: Bool { missed != nil && !isRetrying }
}
