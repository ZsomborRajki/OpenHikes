//
//  DisplayedRoute.swift
//  OpenHikes
//
//  What the map draws: the route's geometry, keyed by id so the map only
//  rebuilds its polyline when the selection changes, and — separately — the
//  route's live appearance, which changes at drag frequency and so is kept out
//  of SwiftUI entirely.
//

import CoreLocation
import SwiftUI

struct DisplayedRoute: Equatable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    /// The stretches of `coordinates` that were inferred rather than measured,
    /// drawn as their own overlays so a guess doesn't look like a
    /// measurement — see ``RouteProvenance``.
    let inferredSegments: [[CLLocationCoordinate2D]]

    /// Defaulted because most callers — every test and every caller that draws
    /// a fully measured route — have nothing to declare here, and a route with
    /// no inferred stretches is the ordinary case.
    init(
        id: UUID,
        coordinates: [CLLocationCoordinate2D],
        inferredSegments: [[CLLocationCoordinate2D]] = []
    ) {
        self.id = id
        self.coordinates = coordinates
        self.inferredSegments = inferredSegments
    }

    /// Coordinates are intentionally excluded: they only ever change together
    /// with `id` (a new hike selection), so comparing `id` is both sufficient
    /// and avoids an O(n) array diff on every SwiftUI update. The inferred
    /// segments are derived from those same coordinates and excluded for the
    /// same reason.
    ///
    /// Tint and width are excluded because they aren't here: they live in
    /// ``RouteStyle``, so a colour, width or pattern drag never reaches this
    /// value — and therefore never reaches the view that builds it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    /// The finished route to draw for the current selection.
    ///
    /// It lives here rather than inline in the view because the properties it
    /// reads — `id` and `isRecording`, plus `route` only on a change of
    /// selection — are the set that decides how often the root view, and with
    /// it the sheet closure inside it, is invalidated. Keeping it in one named
    /// place is what lets a test observe exactly that set; see
    /// `RouteAppearanceIsolationTests`.
    static func forSelection(
        _ hike: Hike?,
        cache: DisplayedRouteCoordinateCache,
        recordingPresented: Bool = false
    ) -> Self? {
        guard !recordingPresented, let hike, !hike.isRecording else { return nil }
        let drawn = cache.drawnRoute(for: hike)
        return Self(
            id: hike.id,
            coordinates: drawn.coordinates,
            inferredSegments: drawn.inferredSegments
        )
    }
}

/// Finished route points are immutable after import or recording finalization,
/// so their Core Location projection is kept across unrelated body passes
/// rather than remapped on each one. Active recording drafts never enter this
/// cache.
final class DisplayedRouteCoordinateCache {
    struct DrawnRoute {
        let coordinates: [CLLocationCoordinate2D]
        let inferredSegments: [[CLLocationCoordinate2D]]

        static let empty = Self(coordinates: [], inferredSegments: [])
    }

    private var hikeID: UUID?
    private var cached: DrawnRoute = .empty

    func coordinates(for hike: Hike) -> [CLLocationCoordinate2D] {
        drawnRoute(for: hike).coordinates
    }

    /// The projected line and the inferred stretches within it, derived
    /// together because they come from one walk of the same route — and cached
    /// together so a body pass that asks for either pays for neither twice.
    func drawnRoute(for hike: Hike) -> DrawnRoute {
        guard hike.id != hikeID else { return cached }
        hikeID = hike.id
        cached = DrawnRoute(
            coordinates: hike.coordinates,
            inferredSegments: hike.route.inferredSegments
        )
        return cached
    }

    func clear() {
        hikeID = nil
        cached = .empty
    }
}

/// The drawn route's tint, width and line pattern, held in a reference type so
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

    /// Written only through ``apply(tint:width:pattern:)``, which restates the
    /// followed hike's appearance on every notification — including the many
    /// that change nothing, since SwiftData notifies on a same-value write to
    /// `tintHex` as readily as on a real one. The map's observer is one `Task`
    /// hop and a renderer invalidation away, and a drag that returns a colour
    /// to where it already was shouldn't pay for either.
    ///
    /// What stops it is Observation's own expansion, which skips an assignment
    /// that compares equal, and all three of these are `Equatable`. Say it out
    /// loud, because the `if`s in `apply` read as though they are the filter
    /// and they are not: delete all three and nothing downstream notices.
    /// They are belt-and-braces over undocumented runtime behaviour, kept for
    /// the same reason as the guard in `HikeRecorder`'s accepted-fix path.
    /// `an equal write to the map's appearance types notifies nobody` in
    /// `ObservationCostTests` is what would go red if that behaviour changed;
    /// without it, this file's quiet would be nobody's decision.
    private(set) var tint: Color = defaultTint
    private(set) var width: Double = defaultWidth
    private(set) var pattern: RouteLinePattern = defaultPattern

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

    /// How many times ``apply(tint:width:pattern:)`` has run.
    ///
    /// A test seam, and the only one this file's stale-callback guard has.
    /// Every apply restates the *currently* tracked hike's appearance, so a
    /// duplicated one writes values that are already there — and Observation
    /// drops an equal write to an `Equatable` property. A stale callback that
    /// slipped through `generation` and armed a second registration is
    /// therefore invisible in `tint`, `width` and `pattern` however many of
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

    /// Tracks `hike`'s tint, width and line pattern, or resets to the defaults
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
            apply(tint: Self.defaultTint, width: Self.defaultWidth, pattern: Self.defaultPattern)
            return
        }
        apply(tint: hike.tint, width: hike.routeWidth, pattern: hike.routeLinePattern)
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
        withObservationTracking {
            _ = hike.tint
            _ = hike.routeWidth
            _ = hike.routeLinePatternID
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard generation == self.generation, let followed = self.trackedHike else { return }
                self.apply(
                    tint: followed.tint,
                    width: followed.routeWidth,
                    pattern: followed.routeLinePattern
                )
                self.track(generation: generation)
            }
        }
    }

    private func apply(tint: Color, width: Double, pattern: RouteLinePattern) {
        appliedCount &+= 1
        if self.tint != tint { self.tint = tint }
        if self.width != width { self.width = width }
        if self.pattern != pattern { self.pattern = pattern }
    }
}
