//
//  PhotoDiscoverySession.swift
//  OpenHikes
//
//  *Find Photos of This Hike*, held where a turn of the phone cannot reach it.
//
//  The hike's screen is drawn in the sheet in portrait and in the side panel
//  in landscape, so a turn replaces the photo section that presents this
//  sheet, and every `@State` it had. Held there, the sheet closed on a turn
//  and took the hiker's choice of photographs with it, and they had to search
//  and choose again (#1462). The hike's ``HikeDetailInteraction`` keeps one of
//  these, and ``SheetPresentation`` keeps that until the hike's last screen
//  leaves the stack, so the section in the new host presents the same sheet
//  again, on the same search.
//
//  A turn is not a close, and the two are told apart by the flag: a sheet
//  the hiker closed has written it back, and one the turn took away has not.
//  So what a presentation is stays the button's to say. *Find Photos of This
//  Hike* starts a new one, and a sheet closed and opened again asks again —
//  see ``PhotoDiscoveryController/reset()``. The sheet built again in the
//  other host goes on with the answer it had rather than asking over the
//  hiker's choice — see ``PhotoDiscoveryController/searchUnlessAnswered(in:)``
//  — and an import under way when the phone turned goes on too.
//

import Observation

@Observable
final class PhotoDiscoverySession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Whether the sheet is up over the hike's screen.
    var isPresented = false
    /// The search, what it found and what the hiker chose. One for as long as
    /// this session, and reset by ``start()`` for each presentation; its own
    /// header says why nothing of one presentation reaches the next.
    let controller: PhotoDiscoveryController

    /// - Parameter controller: Handed in only by a suite. The app's reader is
    ///   resolved by ``PhotoLibrarySource``, which is what lets UI automation
    ///   drive this without a photo library or a permission prompt.
    init(controller: PhotoDiscoveryController = PhotoDiscoveryController(reader: PhotoLibrarySource.reader())) {
        self.controller = controller
    }

    /// *Find Photos of This Hike*: a new question every time, put to a
    /// controller reset in the tap, before the sheet's first pass reads it —
    /// see ``PhotoDiscoveryController/reset()``.
    func start() {
        controller.reset()
        isPresented = true
    }

    /// The sheet has gone. Closed rather than turned, it takes its import
    /// with it — a running import would still be reading full-size photos
    /// for a sheet nobody has open — and a turn leaves the import to land in
    /// the sheet the other host presents again.
    func closed() {
        guard !isPresented else { return }
        controller.cancelImport()
    }

    /// The hike's screens have left the stack, sheet and all: called when
    /// ``SheetPresentation`` lets go of the hike's ``HikeDetailInteraction``,
    /// which is the one close the flag is not written back for.
    func end() {
        isPresented = false
        controller.cancelImport()
    }
}
