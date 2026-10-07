//
//  WalkShareSession.swift
//  OpenHikes
//
//  Sharing one walk, held where a turn of the phone cannot reach it.
//
//  The summary that presents the card is drawn in the sheet in portrait and
//  in the side panel in landscape, so a rotation replaces it and every
//  `@State` it had. Held there, the card closed on a turn and took the chosen
//  photograph and its framing with it (#795). ``SheetPresentation`` keeps one
//  of these for each walk summary on the stack, as it keeps a hike's
//  ``HikeDetailInteraction``, so the summary in the new host presents the
//  same card again, on the same editor.
//

import Observation

@Observable
final class WalkShareSession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Whether the share flow is up over the summary.
    var isPresented = false
    /// The trail's outline with the walk's stretches over it, once fitted.
    var shape: WalkShareRouteShape?
    /// The card being arranged — the chosen photograph, its framing and the
    /// selected box. `nil` until a photograph is chosen.
    var editor: WalkShareEditorModel?
    /// Whether the editor is pushed over the photo choice.
    var isEditing = false
    /// A chosen photograph is still loading. Here rather than in the flow,
    /// because the load outlives a rotation and lands its editor here.
    var isLoading = false
    var loadFailed = false
    /// Which *Share* this is. A photograph still loading when the flow was
    /// closed must not open its editor in the next one.
    @ObservationIgnored private(set) var generation = 0

    /// *Share*, from the photo choice. A rotation re-presents the flow as it
    /// was, but a hiker who closed it and tapped *Share* again starts over,
    /// as they always have.
    func start() {
        clear()
        isPresented = true
    }

    /// The flow has been closed rather than turned: the photograph goes now
    /// rather than when the summary is popped, and a load still on its way
    /// lands nowhere. Called once the cover has gone, so the editor is not
    /// emptied under a card still sliding down.
    func closed() {
        guard !isPresented else { return }
        clear()
    }

    private func clear() {
        generation += 1
        shape = nil
        editor = nil
        isEditing = false
        isLoading = false
        loadFailed = false
    }
}
