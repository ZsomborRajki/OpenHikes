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

    /// Coordinates are intentionally excluded: they only ever change together
    /// with `id` (a new hike selection), so comparing `id` is both sufficient
    /// and avoids an O(n) array diff on every SwiftUI update.
    ///
    /// Tint and width are excluded because they aren't here: they live in
    /// ``RouteStyle``, so a colour, width or pattern drag never reaches this
    /// value — and therefore never reaches the view that builds it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    /// The finished route to draw for the current selection.
    ///
    /// This is the *whole* read `OpenHikesView.body` performs against the
    /// selected `Hike`, which is why it lives here rather than inline in the
    /// view: the property this reads (`id`, and `route` only on a change of
    /// selection) is the property set that decides how often the root view —
    /// and with it the sheet closure inside it — is invalidated. Keeping it in
    /// one named place is what lets a test observe exactly that set.
    static func forSelection(
        _ hike: Hike?,
        cache: DisplayedRouteCoordinateCache,
        recordingPresented: Bool = false
    ) -> Self? {
        guard !recordingPresented, let hike, !hike.isRecording else { return nil }
        return Self(id: hike.id, coordinates: cache.coordinates(for: hike))
    }
}

/// Finished route points are immutable after import or recording finalization,
/// so their Core Location projection is kept across unrelated body passes
/// rather than remapped on each one. Active recording drafts never enter this
/// cache.
final class DisplayedRouteCoordinateCache {
    private var hikeID: UUID?
    private var cached: [CLLocationCoordinate2D] = []

    func coordinates(for hike: Hike) -> [CLLocationCoordinate2D] {
        guard hike.id != hikeID else { return cached }
        hikeID = hike.id
        cached = hike.coordinates
        return cached
    }

    func clear() {
        hikeID = nil
        cached = []
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

    /// Written only through ``apply(tint:width:pattern:)``, which filters a
    /// write that changes nothing — the map's observer is one `Task` hop and a
    /// renderer invalidation away, and a drag that returns a colour to where it
    /// already was shouldn't pay for either.
    private(set) var tint: Color = defaultTint
    private(set) var width: Double = defaultWidth
    private(set) var pattern: RouteLinePattern = defaultPattern

    /// Identifies the current registration. A `withObservationTracking`
    /// callback can only be cancelled by ignoring it, so a notification still
    /// in flight from the previously followed hike carries the generation it
    /// was registered under and is dropped rather than allowed to reinstate
    /// that hike's colour over the newly selected one's.
    @ObservationIgnored private var generation = 0

    /// The hike currently being tracked for style changes.
    @ObservationIgnored private var trackedHike: Hike?

    /// Tracks `hike`'s tint, width and line pattern, or resets to the defaults
    /// with `nil`.
    ///
    /// Called from `OpenHikesView`'s selection change handler — deliberately not
    /// from its `body`, which is the entire point of this type.
    func follow(_ hike: Hike?) {
        generation &+= 1
        guard let hike else {
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
        if self.tint != tint { self.tint = tint }
        if self.width != width { self.width = width }
        if self.pattern != pattern { self.pattern = pattern }
    }
}
