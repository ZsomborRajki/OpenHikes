//
//  TrailDraftController.swift
//  OpenHikes
//
//  Whether the map is offering to make a trail, whether it is currently one
//  big drawing surface, and the one place a waypoint is put down.
//
//  A reference type for the reason ``PhotoCaptureController`` is one, and it
//  is the same geometry: the pill is on the map, the screen it opens is inside
//  the sheet's navigation stack, and the tap that adds a point arrives at
//  `MapView.Coordinator` — three places that cannot see each other. They all
//  attach here instead, and the map observes only what it draws.
//
//  ## The two pills can never both be up, and nothing enforces it
//
//  That is the point of putting the maker in the slot the camera pill already
//  occupies. ``PhotoCaptureController/refreshAvailability()`` is
//  `subject != nil && hasHostScreen`, so the camera is offered only while a
//  screen is pushed *and* that screen has attached a hike to photograph; this
//  one is offered only while **no** screen is pushed. The maker itself is a
//  pushed screen that attaches no photo subject, so opening it withdraws this
//  pill without offering the other. The exclusion falls out of the two
//  definitions rather than out of a rule either of them has to remember, which
//  is why neither of these types knows the other exists.
//
//  ## Every mutation goes through here
//
//  The map appends a waypoint and the maker's screen toggles snapping, cancels
//  and saves — and all of them land on ``TrailDraft`` through this object,
//  because this is the one that also knows the draft has to be written down
//  and that a change to the line is a question for OpenStreetMap. A screen
//  that mutated the draft directly would leave the durable copy behind by
//  exactly one tap and the line unrouted, every time.
//
//  ## Legs are routed one at a time, and a refusal is not retried by itself
//
//  Every pass takes the legs that want an answer and do not have one, marks
//  them, and asks about them **in order, one at a time**. Concurrently would
//  be nineteen simultaneous requests from one phone for a twenty-point trail,
//  which is the shape that earns the `429` this app has already met in the
//  field; sequentially, the second leg usually joins the download the first
//  one started — see ``OverpassTrailLegRouter``.
//
//  A leg that was refused stays refused until the hiker taps *Retry*. Asking
//  again on the next tap would mean one extra request per point put down,
//  aimed at the server that has just said it is busy, and the hiker would see
//  the same sentence appear and disappear without having done anything.
//

import CoreLocation
import Foundation
import Observation

@Observable
final class TrailDraftController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The line being drawn. Handed to the map, which observes it directly, so
    /// a tap that adds a point re-renders no SwiftUI view.
    let draft: TrailDraft

    /// Whether the map should be offering to make a trail. Observed directly
    /// by ``MapView/Coordinator``, so showing or hiding the pill never
    /// re-renders a view.
    private(set) var isAvailable = false

    /// Whether the map is the maker's canvas right now: a tap means *put a
    /// point here* and means nothing else.
    ///
    /// Observed by the coordinator, which is what suspends the drawn-route and
    /// shared-line hit tests while it holds — see `MapCoordinator+RouteTap.swift`.
    /// One tap, one meaning.
    private(set) var isEditing = false

    /// A one-shot request to open the maker, in the shape ``MapController``'s
    /// commands take: a token whose *change* is the message.
    private(set) var openRequest = 0

    /// Whether this maker can make a leg follow a path at all.
    ///
    /// False for a launch with no trail-graph provider — a preview, or UI
    /// automation started without `--ui-test-trail-graph=`. The toggle is
    /// hidden rather than shown switched off, because a control that cannot
    /// change anything is worse than no control: the honest statement is that
    /// this launch draws straight lines.
    var canSnapToPaths: Bool { router != nil }

    /// Where the draft is kept between launches, or `nil` for a launch that
    /// remembers nothing — a preview, or a suite asking only about the pill.
    @ObservationIgnored private let store: TrailDraftStore?

    /// Where a leg's shape comes from, or `nil` for a launch that cannot ask.
    @ObservationIgnored private let router: (any TrailLegRouting)?

    /// The legs a question is currently out about, so a second pass started by
    /// the next tap does not ask about them again beside the first.
    ///
    /// Not on ``TrailDraft`` even though the leg's own
    /// ``TrailLegSnap/routing`` says almost the same thing, because the two
    /// answer different questions: that one is *what should the map draw*, and
    /// a leg can stop being drawn as routing — the hiker turned snapping off —
    /// while the request for it is still on the wire.
    @ObservationIgnored private var legsInFlight: Set<TrailLegEnds> = []

    /// Whether the sheet has any screen pushed. The inverse of what the pill
    /// is offered on; see the note above on why that is the whole exclusion.
    ///
    /// Starts `true`, like ``PhotoCaptureController``'s, so the pill is
    /// withheld until the sheet has said otherwise rather than flashing in
    /// over a launch that restored a pushed screen.
    @ObservationIgnored private var hasPushedScreen = true

    init(store: TrailDraftStore? = nil, router: (any TrailLegRouting)? = nil) {
        self.store = store
        self.router = router
        draft = TrailDraft()
    }

    /// Reports whether the sheet has a screen pushed, which is the whole of
    /// what decides the pill.
    ///
    /// Written by ``MapSheet`` as a function of its navigation path rather
    /// than as a push event, for the reason
    /// ``PhotoCaptureController/setHostScreenPresent(_:)`` is: a pop's
    /// `onDisappear` arrives only after the animation, which would leave this
    /// pill standing over the map and answering taps for the whole of a back
    /// navigation, and an abandoned back-swipe recomputes to the same answer
    /// rather than leaving it withdrawn for good.
    func setHostScreenPresent(_ present: Bool) {
        guard hasPushedScreen != present else { return }
        hasPushedScreen = present
        refreshAvailability()
    }

    /// Reports whether the maker's screen is the one on top.
    ///
    /// Written from the sheet's path for the reason above, and it has to be:
    /// a tap landing on the map during the pop animation would put down a
    /// waypoint on a trail the hiker has just left.
    ///
    /// Opening restores whatever was left half-drawn, and asks about its legs
    /// — a restored draft comes back as points and a setting, never as
    /// resolved shapes, so the line follows the ground again a moment after it
    /// comes back rather than sitting straight until it is touched.
    ///
    /// Closing gives up on whatever is still in flight. Nothing else is owed:
    /// a point going down and the toggle moving are both written as they
    /// happen. A phase that lets a point be dragged or deleted has to write
    /// here too, or leave the disk one gesture behind.
    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if editing {
            restoreIfNeeded()
            resolveLegs()
        } else {
            // The questions already on the wire are not cancelled — the
            // download behind them is shared with the map and with recording,
            // and abandoning it would waste a request that is nearly paid
            // for. They are only disowned: the legs stop being drawn as
            // waiting, the claims are released, and an answer landing
            // afterwards finds no leg asking for it and is dropped. Reopening
            // asks again and the router answers from memory.
            draft.stopRouting()
            legsInFlight.removeAll()
        }
    }

    /// Asks for the maker. Refused when the pill isn't available, so a tap
    /// that races the withdrawal above cannot push a screen from a map that
    /// has stopped offering one.
    func requestOpen() {
        guard isAvailable else { return }
        openRequest &+= 1
    }

    /// Puts a point down at the end of the line.
    ///
    /// Refused unless the maker is up, which is the same guard
    /// ``PhotoCaptureController/requestCamera()`` makes and for the same
    /// reason: the map's recognizer sees every tap, and the one that arrives
    /// as the screen is leaving must not be the one that changes the trail.
    func appendWaypoint(at coordinate: CLLocationCoordinate2D) {
        guard isEditing else { return }
        draft.append(coordinate)
        persist()
        resolveLegs()
    }

    /// Turns path-following on or off, and re-resolves what is already drawn.
    ///
    /// **Re-resolve, not discard.** Turning it off straightens the legs but
    /// keeps the points; turning it back on asks again, and the router answers
    /// the ones it has already been asked from memory, so the line comes back
    /// the way it was without a single request. That is what makes the toggle
    /// something a hiker can try rather than something they have to commit to.
    func setSnapsToPaths(_ snapping: Bool) {
        guard draft.snapsToPaths != snapping else { return }
        draft.setSnapsToPaths(snapping)
        persist()
        resolveLegs()
    }

    /// Asks again about the legs Overpass refused.
    ///
    /// The only thing that does: an ordinary pass leaves a refusal alone, for
    /// the reason the file header gives.
    func retryRefusedLegs() {
        resolveLegs(retryingRefusals: true)
    }

    /// Throws the drawing away: what Cancel does, and what a completed Save
    /// does with what it has just turned into a hike.
    func discard() {
        draft.clear()
        store?.clear()
    }

    private func restoreIfNeeded() {
        // Only into an empty draft. Leaving the maker and coming back within a
        // launch finds the line still in memory, and overwriting it with the
        // copy on disk would undo whatever was added after the last write.
        guard draft.isEmpty, let stored = store?.load(), !stored.isEmpty else { return }
        draft.replace(with: stored.waypoints, snapsToPaths: stored.snapsToPaths)
    }

    private func persist() {
        guard let store else { return }
        guard !draft.isEmpty else {
            store.clear()
            return
        }
        store.save(waypoints: draft.waypoints, snapsToPaths: draft.snapsToPaths)
    }

    private func refreshAvailability() {
        let available = !hasPushedScreen
        guard isAvailable != available else { return }
        isAvailable = available
    }

    /// Asks about every leg that wants an answer and has not been asked.
    ///
    /// One unstructured task per pass rather than one long-lived one, and it
    /// is not cancelled by the next pass: the legs it is working through are
    /// claimed in ``legsInFlight`` before it starts, so the pass a second tap
    /// begins takes only what is left. Cancelling instead would throw away a
    /// download already on the wire every time a hiker put down another point
    /// — which is exactly when they are putting down several.
    private func resolveLegs(retryingRefusals: Bool = false) {
        guard let router, isEditing else { return }
        let pending = draft
            .legsAwaitingRoutes(retryingRefusals: retryingRefusals)
            .filter { ends in !legsInFlight.contains(ends) }
        guard !pending.isEmpty else { return }
        legsInFlight.formUnion(pending)
        draft.beginRouting(pending)
        Task { [weak self] in
            for ends in pending {
                let route = await router.route(ends)
                guard let self else { return }
                receive(route, for: ends)
            }
        }
    }

    /// Takes one answer, whatever has happened to the drawing meanwhile.
    ///
    /// The claim is released either way, so a leg whose answer was cancelled
    /// can be asked about again — by the next tap, or by *Retry*. The draft
    /// itself decides whether the answer still applies: it is matched against
    /// the leg's two ends rather than its place in the list, so a hiker who
    /// added three more points while this was in flight still gets it, and one
    /// who turned snapping off does not. See ``TrailDraft/apply(_:to:)``.
    private func receive(_ route: TrailLegRoute?, for ends: TrailLegEnds) {
        legsInFlight.remove(ends)
        guard let route else { return }
        draft.apply(route, to: ends)
    }
}
