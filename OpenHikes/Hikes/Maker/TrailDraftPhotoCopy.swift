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

import OpenHikesData
import SwiftData
import SwiftUI

@MainActor
@Observable
final class TrailDraftPhotoCopy {
    /// Photographs a save could not copy into its hike.
    struct Missed {
        let hike: Hike
        /// Its name when the copy finished, so the alert never reads a hike
        /// that has been deleted under it.
        let hikeTitle: String
        let photos: TrailDraftPhotoHandOff
    }

    /// What the alert offers again, or `nil` the rest of the time.
    private(set) var missed: Missed?

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
    /// does not.
    @discardableResult func attach(_ handOff: TrailDraftPhotoHandOff, to hike: Hike) -> Task<Void, Never> {
        Task {
            guard let left = await handOff.attach(
                to: hike,
                store: store,
                libraryWriter: libraryWriter,
                save: save
            ) else { return }
            // A later save's misses replace an earlier one's still waiting:
            // one alert, about the trail just made, and the older files go
            // the way *Skip* would have sent them.
            skip()
            missed = Missed(hike: hike, hikeTitle: hike.title, photos: left)
        }
    }

    /// Copies the missed photographs again — only those, since the hike
    /// already holds the rest. Whatever is still missed comes back as a new
    /// alert.
    @discardableResult func retry() -> Task<Void, Never>? {
        guard let missed else { return nil }
        self.missed = nil
        return attach(missed.photos, to: missed.hike)
    }

    /// Lets the missed photographs go, and their files with them.
    func skip() {
        guard let missed else { return }
        self.missed = nil
        missed.photos.discard()
    }

    /// Drives `.alert(isPresented:)`. Its setter does nothing: both buttons
    /// say what happens to the files, and either one clears ``missed``, which
    /// is what closes the alert. Building it reads ``missed`` — see
    /// ``LocationAccessPrompt/isShowingBinding`` for what that makes of the
    /// body that builds it, which is ``TrailDraftPhotoCopyAlert``'s own.
    var isShowingBinding: Binding<Bool> {
        Binding(get: { self.missed != nil }, set: { _ in /* the buttons decide */ })
    }
}

extension View {
    /// Says which of a drawn trail's photographs its save missed, and offers
    /// them again — see ``TrailDraftPhotoCopy``.
    func trailDraftPhotoCopyAlert(_ copy: TrailDraftPhotoCopy) -> some View {
        modifier(TrailDraftPhotoCopyAlert(copy: copy))
    }
}

/// Its own modifier so that the body reading ``TrailDraftPhotoCopy/missed`` is
/// this one, and not that of the view the alert is attached to.
private struct TrailDraftPhotoCopyAlert: ViewModifier {
    let copy: TrailDraftPhotoCopy

    func body(content: Content) -> some View {
        content
            .alert("Photos Not Added", isPresented: copy.isShowingBinding, presenting: copy.missed) { _ in
                Button("Try Again") { copy.retry() }
                Button("Skip", role: .cancel) { copy.skip() }
            } message: { missed in
                Text("""
                    \(missed.photos.photos.count) photos couldn’t be added to “\(missed.hikeTitle)”. \
                    The trail itself is saved.
                    """)
            }
    }
}
