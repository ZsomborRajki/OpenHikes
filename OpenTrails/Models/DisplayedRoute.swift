//
//  DisplayedRoute.swift
//  OpenTrails
//
//  A route to draw on the map, keyed by id so the map only redraws when it changes.
//

import SwiftUI
import CoreLocation

struct DisplayedRoute: Equatable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    /// Line color, including the user's chosen alpha.
    var tint: Color = .green
    /// Line width in points.
    var width: Double = 5

    /// Coordinates are intentionally excluded: they only ever change together
    /// with `id` (a new hike selection), so comparing `id`/`tint`/`width` is
    /// both sufficient and avoids an O(n) array diff on every SwiftUI update.
    static func == (lhs: DisplayedRoute, rhs: DisplayedRoute) -> Bool {
        lhs.id == rhs.id && lhs.tint == rhs.tint && lhs.width == rhs.width
    }
}
