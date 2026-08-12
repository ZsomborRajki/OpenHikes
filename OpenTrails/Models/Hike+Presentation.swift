//
//  Hike+Presentation.swift
//  OpenTrails
//
//  Display-facing helpers derived from a Hike's stored properties.
//

import SwiftUI
import CoreLocation

extension Hike {
    var distance: Measurement<UnitLength> {
        Measurement(value: distanceMeters, unit: .meters)
    }

    /// Full tint including the user's chosen alpha — used for the map polyline.
    var tint: Color { Color(hex: tintHex) ?? .green }

    /// A random, visually distinct route color — fixed saturation/brightness so
    /// every hue stays legible on the map and in the UI. Used to give each
    /// newly imported hike its own default tint instead of always green.
    static func randomTintHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomTintHex(using: &generator)
    }

    /// The same tint, from a caller-supplied source of randomness — so a test
    /// that sweeps hundreds of generated tints can seed it and reproduce a
    /// failure on exactly the hue that caused it.
    static func randomTintHex<G: RandomNumberGenerator>(using generator: inout G) -> String {
        Color(hue: .random(in: 0..<1, using: &generator), saturation: 0.65, brightness: 0.85).hexRGBA
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
