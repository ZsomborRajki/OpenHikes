//
//  Hike+Presentation.swift
//  OpenHikes
//
//  Display-facing helpers derived from a Hike's stored properties.
//

import CoreLocation
import SwiftUI

extension Hike {
    /// The name shown everywhere in the UI. Returns ``customName`` when the
    /// user has set one, otherwise falls back to the original ``title``.
    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        return title
    }

    var distance: Measurement<UnitLength> {
        Measurement(value: distanceMeters, unit: .meters)
    }

    /// Full tint including the user's chosen alpha — used for the map polyline.
    var tint: Color { Color(hex: tintHex) ?? .green }

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

    /// A random, visually distinct route color, so each newly imported hike
    /// gets its own default tint instead of always green.
    ///
    /// The palette it comes out of is ``RouteTint``, which a community listing
    /// draws from too — by identity rather than by chance, since a listing has
    /// nowhere to keep the answer.
    static func randomTintHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomTintHex(using: &generator)
    }

    /// The same tint, from a caller-supplied source of randomness — so a test
    /// that sweeps generated tints can seed it and reproduce a failure on
    /// exactly the hue that caused it.
    static func randomTintHex<G: RandomNumberGenerator>(using generator: inout G) -> String {
        RouteTint.random(using: &generator).hexRGBA
    }

    /// Tint forced fully opaque — used everywhere except the map line (graph,
    /// list-row circle, header icon, highlight dot), so transparency reads only
    /// on the route itself.
    var tintOpaque: Color { tint.opaque }

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
