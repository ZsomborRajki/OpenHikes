//
//  Hike+Naming.swift
//  OpenHikesData
//
//  What a hike is called and how long it is, read the same way by the app,
//  the library's orders and anything else that has a `Hike` in hand. The
//  colours drawn for it stay in the app beside SwiftUI — see
//  `Hike+Presentation.swift`.
//

import CoreLocation
import Foundation

public extension Hike {
    /// The name shown everywhere in the UI. Returns ``customName`` when the
    /// user has set one, otherwise falls back to the original ``title``.
    ///
    /// `nonisolated`, because it reads nothing but two of the model's own
    /// columns, and the widget's background match reads it off the main actor
    /// from a context of its own — see ``HikeRouteInput``.
    nonisolated var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        return title
    }

    var distance: Measurement<UnitLength> {
        Measurement(value: distanceMeters, unit: .meters)
    }

    /// The stored line pattern as the map and the picker use it. An id no build
    /// recognises resolves to the default, so the route is always drawable.
    var routeLinePattern: RouteLinePattern {
        get { RouteLinePattern(storedID: routeLinePatternID) }
        set { routeLinePatternID = newValue.rawValue }
    }

    /// The tint a hike has when nothing chose one for it.
    ///
    /// A mirror of the literal on ``Hike/tintHex`` rather than the source of
    /// it: a mirrored CloudKit column's default has to be an inline literal
    /// on the declaration, so the model keeps its own copy and this exists for
    /// the callers — the Live Activity among them — that need the same answer
    /// without a `Hike` in hand.
    static let defaultTintHex = "#1B7F3B"

    /// "5.2 km · Jun 12, 2026" — length and record/import date.
    var subtitle: String {
        let length = distance.formatted(
            .measurement(width: .abbreviated, usage: .road)
        )
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return "\(length) · \(day)"
    }

    var coordinates: [CLLocationCoordinate2D] {
        route.map(\.clCoordinate)
    }
}
