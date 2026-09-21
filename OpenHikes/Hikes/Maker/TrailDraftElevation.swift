//
//  TrailDraftElevation.swift
//  OpenHikes
//
//  What the trail being drawn climbs, and what it drops.
//
//  A line on a map is geometry with no terrain under it. The length is
//  arithmetic the app already has — every leg carries its own — but the climb
//  is the figure that actually decides whether Saturday is a walk or a day
//  out, and there is nothing in OpenStreetMap's walking graph that can answer
//  it: measured while the curated feature was built, `ele` was on **zero** of
//  1,725 geometry nodes. So this asks the one elevation source this app
//  already carries a key for — ``StadiaElevationSource``, through
//  ``CuratedElevationSourcing`` — and the whole of what it adds to that is
//  *when*.
//
//  ## When, because a drawn line is not a route that was opened once
//
//  A curated hike is asked about once, on open, and never again. A drawing
//  changes under the question: every tap adds a point, every leg that snaps
//  reshapes the line without the hiker touching anything, and each of those is
//  a different trail with a different climb. Asking per change would spend a
//  **billed** call per tap against the key the paid map styles are behind.
//
//  So the question waits for the drawing to settle — ``settleSeconds`` of
//  nothing happening — and every change before that cancels the one before it.
//  A hiker putting five points down in a row asks one question, not five, and
//  a leg landing two seconds after the last tap is folded into the same one.
//  That is a debounce rather than a barrier, which is the distinction the
//  repository instructions draw: what is being waited on here *is* a duration,
//  because "the hiker has stopped drawing" has no other observable form.
//
//  ## What is measured is thrown away the moment the line moves
//
//  There is no stale figure and no figure marked as stale. The header carries
//  a climb for the line in front of the hiker or it carries nothing, because a
//  climb beside a length that describes a different line is the one answer
//  worse than no answer. The consequence is visible and is the right one: the
//  figure goes when a point goes down and comes back a couple of seconds
//  later.
//
//  ## Nothing here may ever block drawing, or saving
//
//  The line, the legs, the list and Save do not know this file exists. A free
//  hiker's drawn trail, a build with no key and a refused request are all the
//  same state — no figures and no chart — which is exactly how a curated route
//  behaves today. And a Save that happens while a question is out saves what
//  is in hand: see ``TrailDraftSave``, which does not wait for Overpass either.
//

import Foundation
import Observation

/// The heights of the trail being drawn, and the one thing that asks for them.
///
/// A stable `@Observable` reference type for the reason ``TrailDraft`` and
/// ``TrailPointFinder`` are, and it is the same geometry a third time: the
/// answer arrives on its own schedule from a task nobody is watching, the
/// figure is drawn in a section header two pushes down inside the sheet, and
/// the route it describes is owned by neither.
///
/// Held beside the draft rather than on it, like the finder, because none of
/// it is the drawing: nothing here is written down, restored or saved on its
/// own, and closing the maker forgets all of it.
@Observable
final class TrailDraftElevation {
    /// How long the drawing has to stand still before it is worth asking
    /// about, in seconds.
    ///
    /// Two, and it is a bargain between a bill and a figure. A hiker putting
    /// points down does it about once a second, so anything shorter asks a
    /// billed question per tap; anything much longer and the figure arrives
    /// after they have stopped looking for it. Picked by argument — the thing
    /// that would settle it is a hiker with a phone, not a paragraph.
    static let settleSeconds: TimeInterval = 2

    /// What the line climbs and drops, or `nil` for a line nothing has
    /// measured yet.
    ///
    /// The observed half, and the only one. Read by the one small view that
    /// draws it — see ``TrailDraftLineHeader`` — which is what keeps an answer
    /// landing from rebuilding the list of points above it.
    private(set) var summary: RouteElevationSummary?

    /// Whether a question is out right now.
    ///
    /// Drawn as the same small spinner the *Search this area* pill uses, in
    /// the header's own figure slot — see ``TrailDraftLineHeader``. It says
    /// *a number is coming*, which is the one thing a hiker who has just drawn
    /// a long loop wants to know and the one thing an empty slot cannot tell
    /// them.
    ///
    /// It is false for the whole of an active drawing: the debounce in front
    /// of the question keeps restarting, so this turns on once, after the
    /// hiker stops, for as long as one request takes.
    private(set) var isMeasuring = false

    /// The heights themselves, and the points they were read at.
    ///
    /// **Untracked**, deliberately, and it is the same split ``TrailDraft``
    /// makes between a drag and its revision: this is read in an action —
    /// Save, once — and never in a body, while the figure beside it is read in
    /// a body and never in an action. Publishing both would make an answer
    /// landing two invalidations instead of one, for a value nothing draws.
    @ObservationIgnored private(set) var samples: RouteHeightSamples?

    /// Whether this launch can ask at all.
    ///
    /// False for a preview and for every launch running tests — see
    /// ``OpenHikesModel/makeTrailElevationSource()``. Nothing is scheduled at
    /// all when it is false, which is what keeps a suite from holding a timer
    /// it never uses.
    var isAvailable: Bool { source != nil }

    @ObservationIgnored private let draft: TrailDraft
    @ObservationIgnored private let source: (any CuratedElevationSourcing)?
    @ObservationIgnored private let pause: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - draft: read when the drawing settles rather than handed in per
    ///     change, because the flattened line is thousands of coordinates once
    ///     the legs have snapped and building it per tap to hand to a question
    ///     that is about to be cancelled is the cost this type exists to
    ///     avoid.
    ///   - source: `nil` for a launch that must not ask — see ``isAvailable``.
    ///   - pause: See *Deliberate test seams* in the repository instructions.
    ///     A debounce is only observable against a clock somebody else is
    ///     holding, and a suite that waited two real seconds per assertion
    ///     would be the slowest thing in the bundle.
    init(
        draft: TrailDraft,
        source: (any CuratedElevationSourcing)? = nil,
        pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.draft = draft
        self.source = source
        self.pause = pause
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The line moved: whatever was measured is about a trail that no longer
    /// exists.
    ///
    /// Called from every edit that changes the *line* and from every leg that
    /// lands — see ``TrailDraftController``. Not from an edit that only
    /// touches a place, which changes no geometry and would otherwise spend a
    /// billed call to be told the same number.
    func drawingDidChange() {
        guard isAvailable else { return }
        // Before the reschedule, so the figure goes the instant the line does
        // rather than when the next answer disagrees with it.
        forget()
        task = Task { [weak self] in
            guard let self else { return }
            try? await pause(Self.settleSeconds)
            guard !Task.isCancelled else { return }
            await measure()
        }
    }

    /// Forgets everything and stops asking. What closing the maker does, and
    /// what a saved or discarded drawing does.
    func clear() {
        forget()
        task = nil
    }

    /// `route` with the heights that were read for it, or `route` exactly as
    /// it came.
    ///
    /// The one thing Save asks of this file, and it answers without waiting
    /// for anything: a drawing whose heights have not landed is saved with a
    /// line and a length and no profile, which is what a free hiker's drawn
    /// trail is always saved as and what a curated route with no heights
    /// already looks like.
    func filling(_ route: [RouteCoordinate]) -> [RouteCoordinate] {
        samples?.filling(route) ?? route
    }

    /// One question, asked about the line as it now stands.
    private func measure() async {
        guard let source else { return }
        let route = draft.routeCoordinates
        // One point is a place rather than a trail, and has no climb —
        // ``TrailDraftSave`` refuses to save it for the same reason.
        guard route.count > 1 else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        let measured = await source.samples(of: route)
        // After the await rather than before: the drawing may have moved while
        // the answer was in flight, and this task is the thing
        // ``drawingDidChange()`` cancels when it does.
        guard !Task.isCancelled, let measured else { return }
        samples = measured
        summary = measured.summary
    }

    /// Drops the answer and cancels whatever was going to replace it.
    ///
    /// ``isMeasuring`` goes with it rather than waiting for the cancelled
    /// request to notice: what it says is *a number is coming for the line you
    /// are looking at*, and the moment that line changes it is no longer true
    /// of the question that is out.
    private func forget() {
        task?.cancel()
        isMeasuring = false
        samples = nil
        summary = nil
    }
}
