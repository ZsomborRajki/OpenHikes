//
//  MapState.swift
//  OpenHikes
//
//  Reference-type state observed directly by the map (not via SwiftUI), so
//  drag/scrub-frequency updates never re-render a SwiftUI view.
//

import Foundation
import MapKit

/// The scrub-highlight location, held in a reference type so it can be updated at
/// drag frequency *without* re-rendering any SwiftUI view. The map observes it
/// directly and moves a single annotation.
@Observable
final class RouteHighlight {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Written only through ``move(to:)``, which is what keeps a repeat position
    /// from waking the map — see there.
    private(set) var coordinate: CLLocationCoordinate2D?

    /// Moves the highlight, or clears it with `nil`, and notifies the map only
    /// when that actually changes where the pin belongs.
    ///
    /// `CLLocationCoordinate2D` isn't `Equatable`, so Observation can't filter
    /// a repeat write the way it does for `Double` and friends — it has to be
    /// compared here. It matters most on the hot path this type exists for:
    /// scrubbing the elevation chart interpolates positions along route
    /// segments, and repeated drag samples at the same distance would otherwise
    /// re-register the map coordinator's observation through a `Task` hop for
    /// no movement.
    ///
    /// Guarding here rather than at each call site is deliberate: the write
    /// sites are spread across the detail view's scrub, its auto-follow poll
    /// and its toggles, and a missed guard is invisible until someone profiles
    /// a drag.
    func move(to coordinate: CLLocationCoordinate2D?) {
        switch (self.coordinate, coordinate) {
        case (nil, nil): return
        case let (current?, next?)
            where current.latitude == next.latitude && current.longitude == next.longitude: return
        default: self.coordinate = coordinate
        }
    }
}

/// The sheet's live top edge (global Y), held in a reference type so the sheet can
/// update it at drag frequency *without* re-rendering any SwiftUI view. The map
/// observes it directly and repositions the "my location" button.
@Observable
final class SheetMetrics {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    var topY: CGFloat = 0

    /// Where the sheet comes to rest at its middle detent.
    ///
    /// Learned by watching the sheet rather than computed from the screen,
    /// because there is no fraction that works: the system's medium detent
    /// rests 43% of the way down an iPhone 17 Pro and 48% down an iPhone 14
    /// Pro Max, and the gap between those is wider than the room the "my
    /// location" button needs above it. A guess is therefore either too low to
    /// be useful or low enough to push the button behind the sheet.
    ///
    /// `nil` until the sheet has been seen resting there — the map falls back
    /// to keeping the button clear of the status bar until then.
    private(set) var middleRestY: CGFloat?

    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var lastReportAt: Date?
    @ObservationIgnored private var awaitingMiddleRest = true

    /// Longer than a stutter, shorter than a pause a hand would make. Only
    /// used to tell "the sheet is sitting still" from "the sheet is moving".
    private static let restGap: TimeInterval = 0.2

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Reports the sheet's top edge, and whether the sheet is currently
    /// committed to its middle detent.
    ///
    /// Doubles as where ``middleRestY`` is learned. A drag reports at display
    /// rate, so a gap between two reports means the sheet stopped in between —
    /// and if it stopped while committed to the middle detent, the value it
    /// stopped at is that detent's resting place. The detent binding can't
    /// answer this on its own: it stays on the middle detent for the whole
    /// drag towards the large one and only changes when the drag is released.
    ///
    /// Learned once per visit, so a hand pausing mid-drag isn't mistaken for
    /// the sheet resting.
    func report(topY: CGFloat, atMiddleDetent: Bool) {
        let now = clock()
        defer {
            lastReportAt = now
            self.topY = topY
        }
        guard atMiddleDetent, awaitingMiddleRest, let lastReportAt else { return }
        guard now.timeIntervalSince(lastReportAt) > Self.restGap else { return }
        middleRestY = self.topY
        awaitingMiddleRest = false
    }

    /// Re-arms the learning above whenever the sheet commits to a detent, so
    /// the resting place is measured again after every visit — it moves with
    /// rotation, and with anything else that changes the sheet's height.
    func detentCommitted(toMiddle: Bool) {
        awaitingMiddleRest = toMiddle
    }
}

/// One-shot map commands the detail view issues (e.g. the Zoom button). Held in a
/// reference type the map observes directly, so triggering one doesn't re-render
/// any SwiftUI view. `fitRouteRequest` is a token — bumping it asks the map to
/// re-fit the current route into view.
@Observable
final class MapController {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var fitRouteRequest: Int = 0
    private(set) var showRegionRequest: Int = 0
    private(set) var followUserRequest: Int = 0
    private(set) var region: MKCoordinateRegion?

    /// Ask the map to zoom to fit the currently drawn route.
    func fitToRoute() { fitRouteRequest += 1 }

    /// Ask the map to zoom to a region (e.g. a search result).
    func show(_ region: MKCoordinateRegion) {
        self.region = region
        showRegionRequest += 1
    }

    /// Ask the map to follow the user until they pan away.
    func followUser() {
        followUserRequest += 1
    }
}
