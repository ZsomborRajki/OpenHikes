//
//  MapControllers.swift
//  OpenTrails
//
//  Reference-type state observed directly by the map (not via SwiftUI), so
//  drag/scrub-frequency updates never re-render a SwiftUI view.
//

import Foundation
import MapKit

/// The scrub-highlight location, held in a reference type so it can be updated at
/// drag frequency *without* re-rendering any SwiftUI view. The map observes it
/// directly and moves a single annotation.
@MainActor
@Observable
final class RouteHighlight {
    /// Written only through ``move(to:)``, which is what keeps a repeat position
    /// from waking the map — see there.
    private(set) var coordinate: CLLocationCoordinate2D?

    /// Moves the highlight, or clears it with `nil`, and notifies the map only
    /// when that actually changes where the pin belongs.
    ///
    /// `CLLocationCoordinate2D` isn't `Equatable`, so Observation can't filter
    /// a repeat write the way it does for `Double` and friends — it has to be
    /// compared here. It matters most on the hot path this type exists for:
    /// scrubbing the elevation chart resolves a distance to the *nearest track
    /// point*, so a finger crossing one vertex's worth of trail reports the
    /// same coordinate many times over, and each repeat would re-register the
    /// map coordinator's observation through a `Task` hop for no movement.
    ///
    /// Guarding here rather than at each call site is deliberate: the write
    /// sites are spread across the detail view's scrub, its auto-follow poll
    /// and its toggles, and a missed guard is invisible until someone profiles
    /// a drag.
    func move(to coordinate: CLLocationCoordinate2D?) {
        switch (self.coordinate, coordinate) {
        case (nil, nil):
            return
        case let (current?, next?)
            where current.latitude == next.latitude && current.longitude == next.longitude:
            return
        default:
            self.coordinate = coordinate
        }
    }
}

/// The sheet's live top edge (global Y), held in a reference type so the sheet can
/// update it at drag frequency *without* re-rendering any SwiftUI view. The map
/// observes it directly and repositions the "my location" button.
@MainActor
@Observable
final class SheetMetrics {
    var topY: CGFloat = 0
}

/// One-shot map commands the detail view issues (e.g. the Zoom button). Held in a
/// reference type the map observes directly, so triggering one doesn't re-render
/// any SwiftUI view. `fitRouteRequest` is a token — bumping it asks the map to
/// re-fit the current route into view.
@MainActor
@Observable
final class MapController {
    private(set) var fitRouteRequest: Int = 0
    private(set) var showRegionRequest: Int = 0
    private(set) var region: MKCoordinateRegion?

    /// Ask the map to zoom to fit the currently drawn route.
    func fitToRoute() { fitRouteRequest += 1 }

    /// Ask the map to zoom to a region (e.g. a search result).
    func show(_ region: MKCoordinateRegion) {
        self.region = region
        showRegionRequest += 1
    }
}
