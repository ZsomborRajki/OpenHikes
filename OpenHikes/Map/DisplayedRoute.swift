//
//  DisplayedRoute.swift
//  OpenHikes
//
//  What the map draws: the route's geometry, keyed by id so the map only
//  rebuilds its polyline when the selection changes and projected off the
//  main actor before the root body ever reads it, and — separately — the
//  route's live appearance, which changes at drag frequency and so is kept out
//  of SwiftUI entirely.
//

import CoreLocation
import OpenHikesData
import OpenHikesShared
import SwiftUI

struct DisplayedRoute: Equatable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    /// The stretches of `coordinates` that were inferred rather than measured,
    /// drawn as their own overlays so a guess doesn't look like a
    /// measurement — see ``RouteProvenance``.
    let inferredSegments: [[CLLocationCoordinate2D]]
    /// The stretches of `coordinates` the recording was paused across, drawn
    /// as their own overlays so a walk with a break in it doesn't read as one
    /// continuous line — see ``RouteBoundary``.
    let pausedSegments: [[CLLocationCoordinate2D]]
    /// `coordinates` cut at their pauses, which is where the route line is
    /// cut: a paused leg is not trail (#962), so the line is drawn walked run
    /// by walked run and only the dotted stretch above crosses each pause
    /// (#1034). See ``TrailRuns``.
    let runs: TrailRuns

    /// The segment lists and the cut are defaulted because most callers —
    /// every test and every caller that draws a fully measured, uninterrupted
    /// route — have nothing to declare here, and that is the ordinary case:
    /// with no `runs`, the line is one run.
    init(
        id: UUID,
        coordinates: [CLLocationCoordinate2D],
        inferredSegments: [[CLLocationCoordinate2D]] = [],
        pausedSegments: [[CLLocationCoordinate2D]] = [],
        runs: TrailRuns? = nil
    ) {
        self.id = id
        self.coordinates = coordinates
        self.inferredSegments = inferredSegments
        self.pausedSegments = pausedSegments
        self.runs = runs ?? TrailRuns(pointCount: coordinates.count, pauseIndices: [])
    }

    /// Coordinates are intentionally excluded: they only ever change together
    /// with `id` (a new hike selection), so comparing `id` is both sufficient
    /// and avoids an O(n) array diff on every SwiftUI update. The inferred
    /// segments and the paused ones are derived from those same coordinates
    /// and excluded for the same reason.
    ///
    /// Tint and width are excluded because they aren't here: they live in
    /// ``RouteStyle``, so a colour, width, pattern or border change never reaches this
    /// value — and therefore never reaches the view that builds it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    /// The finished route to draw for the current selection.
    ///
    /// It lives here rather than inline in the view because the properties it
    /// reads — `id` and `isRecording`, plus whatever the cache has prepared —
    /// are the set that decides how often the root view, and with it the
    /// sheet closure inside it, is invalidated. Keeping it in one named place
    /// is what lets a test observe exactly that set; see
    /// `RouteAppearanceIsolationTests`. `route` is not in it: the cache is
    /// filled outside the body, and `nil` here until it has been is a route
    /// not drawn yet rather than a route with nothing in it.
    static func forSelection(
        _ hike: Hike?,
        cache: DisplayedRouteCoordinateCache,
        recordingPresented: Bool = false
    ) -> Self? {
        guard !recordingPresented, let hike, !hike.isRecording,
              let drawn = cache.drawnRoute(for: hike) else { return nil }
        return Self(
            id: hike.id,
            coordinates: drawn.coordinates,
            inferredSegments: drawn.inferredSegments,
            pausedSegments: drawn.pausedSegments,
            runs: drawn.runs
        )
    }
}

/// The selected route's Core Location projection, prepared outside the body
/// that draws it and kept across that body's unrelated passes.
///
/// Finished route points are immutable after import or recording
/// finalization, so one projection per selection is enough. Active recording
/// drafts never enter this cache.
///
/// **Projected off the main actor, from the selection's change handler
/// (#1232).** Projecting a route maps every point to Core Location and walks
/// the route twice more for its inferred stretches, its paused ones and its
/// runs. That used to happen on the root body's first pass after a selection,
/// on the main actor: about 12 ms of a 20,000-point trail's 40, and 130 of a
/// 200,000-point one's 410, measured on the simulator. Now the body only
/// reads what ``prepare(for:)`` has published, and `prepare` hands the route
/// to ``projectOffMain(_:build:)`` and publishes the answer when it lands.
/// The root body runs once more for that, the one observable write this type
/// makes per selection.
///
/// The route itself is read where the hike lives, on the main actor, and only
/// the projection leaves. That read is the rest of those figures — a route not
/// read yet is external storage decoded whole — but it is paid once per
/// context, and the selection handler that calls `prepare` pays it there
/// anyway: ``BackgroundTrailTracker``'s `HikeRouteInput` reads `hike.route`
/// in the same handler whenever no walk is holding it, and ``RouteShading`` and
/// auto-save's corridor read it when they have work to do. A context of its
/// own would decode a second copy off the main actor and leave the first
/// where it is; the decode leaves the main actor only when all of them do.
@Observable
final class DisplayedRouteCoordinateCache {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``RouteStyle``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    nonisolated struct DrawnRoute: Sendable {
        let coordinates: [CLLocationCoordinate2D]
        let inferredSegments: [[CLLocationCoordinate2D]]
        let pausedSegments: [[CLLocationCoordinate2D]]
        let runs: TrailRuns

        /// The projected line and the stretches within it the map has to
        /// draw differently — inferred and paused — derived together because
        /// they come from one walk of the same route.
        init(route: [RouteCoordinate]) {
            coordinates = route.map(\.clCoordinate)
            inferredSegments = route.inferredSegments
            pausedSegments = route.pausedSegments
            runs = route.trailRuns
        }
    }

    /// A projection, and the hike it is the projection of.
    struct Prepared {
        let hikeID: UUID
        let route: DrawnRoute
    }

    /// The one property the root body observes: written when a projection
    /// lands and when the selection clears, and at no other time.
    private var prepared: Prepared?

    /// The hike the projection above belongs to, or is being made for, so a
    /// handler pass that does not change the selection starts nothing.
    @ObservationIgnored private var hikeID: UUID?
    /// Identifies the current request, so a projection still in flight for a
    /// selection that has since moved on is dropped rather than published
    /// over the one that replaced it — the arrangement ``RouteShading``'s
    /// own `generation` explains.
    @ObservationIgnored private var generation = 0
    /// The projection in flight, if any. Readable so a suite can wait on the
    /// effect rather than on a duration.
    @ObservationIgnored private(set) var preparation: Task<Void, Never>?
    /// What a projection is, as a seam so a suite can see which thread made
    /// it. ``DrawnRoute/init(route:)`` everywhere else.
    @ObservationIgnored private let build: @Sendable ([RouteCoordinate]) -> DrawnRoute

    init(build: @escaping @Sendable ([RouteCoordinate]) -> DrawnRoute = DrawnRoute.init(route:)) {
        self.build = build
    }

    /// What the body draws for `hike`: its projection once it has landed,
    /// and nothing until then.
    func drawnRoute(for hike: Hike) -> DrawnRoute? {
        guard let prepared, prepared.hikeID == hike.id else { return nil }
        return prepared.route
    }

    /// Starts projecting `hike`'s route, or clears the cache with `nil`.
    ///
    /// Called from `OpenHikesView`'s selection change handler — deliberately
    /// not from its `body`, which is the entire point of this type. A
    /// recording's draft is left alone: its line is the recorder's to draw,
    /// and the change that finishes it calls here again.
    func prepare(for hike: Hike?) {
        guard let hike else {
            clear()
            return
        }
        guard !hike.isRecording, hike.id != hikeID else { return }
        hikeID = hike.id
        generation &+= 1
        let started = generation
        let id = hike.id
        let route = hike.route
        let project = build
        preparation = Task { [weak self] in
            let drawn = await Self.projectOffMain(route, build: project)
            guard let self, started == generation else { return }
            prepared = Prepared(hikeID: id, route: drawn)
        }
    }

    /// Projects `route` off the main actor.
    ///
    /// `@concurrent`, because a `nonisolated async` function runs on its
    /// caller's executor, and the caller is the main actor.
    @concurrent
    nonisolated static func projectOffMain(
        _ route: [RouteCoordinate],
        build: @Sendable ([RouteCoordinate]) -> DrawnRoute
    ) async -> DrawnRoute {
        assertOffMainThread("Projecting the selected route must stay off the main thread")
        return build(route)
    }

    private func clear() {
        generation &+= 1
        hikeID = nil
        preparation = nil
        // `Prepared` is not `Equatable`, so Observation would notify the body
        // for a `nil` written over `nil`.
        if prepared != nil { prepared = nil }
    }
}

/// The drawn route's tint, width, line pattern and border, held in a reference type so
/// the controls that write them — a `ColorPicker` drag, a `Slider` drag, both
/// continuous, and the pattern picker — never re-render a SwiftUI view above
/// the map. The map observes this directly and restyles its existing polyline
/// renderer in place; the same technique ``RouteHighlight`` and ``SheetMetrics``
/// use.
///
/// The hike remains the source of truth (it is what persists, and what the
/// detail view's controls write). This follows it rather than being written
/// alongside it, so there is no second place a colour can be set and no pair of
/// values that can drift apart.
@Observable
final class RouteStyle {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — deinit does nothing actor-sensitive, and
    /// without this, dropping a `RouteStyle` off the main actor (e.g. a
    /// main-actor-isolated test suite instance deallocated on Swift Testing's
    /// cooperative pool) traps in `MainActor.assumeIsolated`.
    nonisolated deinit { /* intentionally empty */ }

    /// `Hike.tint`'s own fallback and `Hike`'s own initial width, so an
    /// unfollowed style is the one a freshly imported trail would have rather
    /// than a third set of values to reason about.
    static let defaultTint: Color = .green
    static let defaultWidth: Double = 3
    static let defaultPattern: RouteLinePattern = .default
    /// Opaque black — what the empty ``Hike/routeBorderHex`` every hike
    /// starts with resolves to, so a line reads against any map, and against
    /// the yellow and green stretches the route colouring paints on it, until
    /// the hiker picks something else. Fading the border to zero opacity is
    /// still how it is taken off.
    static let defaultBorder: Color = .black

    /// Written only through ``apply(tint:width:pattern:border:)``, which restates the
    /// followed hike's appearance on every notification — including the many
    /// that change nothing, since SwiftData notifies on a same-value write to
    /// `tintHex` as readily as on a real one. The map's observer is one `Task`
    /// hop and a renderer invalidation away, and a drag that returns a colour
    /// to where it already was shouldn't pay for either.
    ///
    /// What stops it is Observation's own expansion, which skips an assignment
    /// that compares equal, and all four of these are `Equatable`. Say it out
    /// loud, because the `if`s in `apply` read as though they are the filter
    /// and they are not: delete all four and nothing downstream notices.
    /// They are belt-and-braces over undocumented runtime behaviour, kept for
    /// the same reason as the guard in `HikeRecorder`'s accepted-fix path.
    /// `an equal write to the map's appearance types notifies nobody` in
    /// `ObservationCostTests` is what would go red if that behaviour changed;
    /// without it, this file's quiet would be nobody's decision.
    private(set) var tint: Color = defaultTint
    private(set) var width: Double = defaultWidth
    private(set) var pattern: RouteLinePattern = defaultPattern
    private(set) var border: Color = defaultBorder

    /// Identifies the current registration. A `withObservationTracking`
    /// callback can only be cancelled by ignoring it, so a notification still
    /// in flight from the previously followed hike carries the generation it
    /// was registered under and is dropped rather than allowed to reinstate
    /// that hike's colour over the newly selected one's.
    ///
    /// Redundant with the `self.trackedHike` re-read beside it for *that*
    /// purpose — mutation-tested, either alone keeps the stale colour out — but
    /// not for its other one: it is also what stops a stale callback re-arming
    /// a second `withObservationTracking` registration, so every subsequent
    /// write would be applied once per hike ever followed. That second purpose
    /// is what `a stale callback neither applies nor arms a second
    /// registration` in `RouteStyleTrackingTests` holds, through
    /// ``appliedCount``.
    @ObservationIgnored private var generation = 0

    /// How many times ``apply(tint:width:pattern:border:)`` has run.
    ///
    /// A test seam, and the only one this file's stale-callback guard has.
    /// Every apply restates the *currently* tracked hike's appearance, so a
    /// duplicated one writes values that are already there — and Observation
    /// drops an equal write to an `Equatable` property. A stale callback that
    /// slipped through `generation` and armed a second registration is
    /// therefore invisible in `tint`, `width`, `pattern` and `border` however many of
    /// them pile up; only the amount of work changes, so the work is what is
    /// counted. `@ObservationIgnored` because a counter that notified would be
    /// the very cost it exists to measure.
    @ObservationIgnored private(set) var appliedCount = 0

    /// The hike currently being tracked for style changes.
    ///
    /// Readable rather than fully private so a test can assert that following
    /// `nil` lets go of it: the reference is never *acted* on once
    /// `generation` moves, so nothing else observable would distinguish a
    /// cleared field from a stale one.
    @ObservationIgnored private(set) var trackedHike: Hike?

    /// Tracks `hike`'s tint, width, line pattern and border, or resets to the defaults
    /// with `nil`.
    ///
    /// Called from `OpenHikesView`'s selection change handler — deliberately not
    /// from its `body`, which is the entire point of this type.
    func follow(_ hike: Hike?) {
        generation &+= 1
        guard let hike else {
            // Cleared here rather than only overwritten by the next non-nil
            // follow: the reference is harmless — `track(generation:)`
            // re-guards, so a stale one is never acted on — but a `RouteStyle`
            // that has been told to follow nothing should not still be holding
            // a `Hike` from the store.
            trackedHike = nil
            apply(
                tint: Self.defaultTint,
                width: Self.defaultWidth,
                pattern: Self.defaultPattern,
                border: Self.defaultBorder
            )
            return
        }
        apply(tint: hike.tint, width: hike.routeWidth, pattern: hike.routeLinePattern, border: hike.routeBorder)
        trackedHike = hike
        track(generation: generation)
    }

    /// Observes the followed hike's appearance imperatively and re-registers
    /// after each notification, exactly as `MapView.Coordinator` does for its
    /// own observations. The values are re-read in the callback rather than
    /// carried by it, so two writes landing in one turn — the second of which
    /// arrives while no registration is armed — still converge on the latest.
    private func track(generation: Int) {
        guard let hike = trackedHike else { return }
        reobserving(self) {
            _ = hike.tint
            _ = hike.routeWidth
            _ = hike.routeLinePatternID
            _ = hike.routeBorderHex
        } onChange: { route in
            guard generation == route.generation, let followed = route.trackedHike else { return }
            route.apply(
                tint: followed.tint,
                width: followed.routeWidth,
                pattern: followed.routeLinePattern,
                border: followed.routeBorder
            )
            route.track(generation: generation)
        }
    }

    private func apply(tint: Color, width: Double, pattern: RouteLinePattern, border: Color) {
        appliedCount &+= 1
        if self.tint != tint { self.tint = tint }
        if self.width != width { self.width = width }
        if self.pattern != pattern { self.pattern = pattern }
        if self.border != border { self.border = border }
    }
}
