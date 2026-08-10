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
    var coordinate: CLLocationCoordinate2D?
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
