//
//  Hike+Presentation.swift
//  OpenHikes
//
//  The colours a hike is drawn in — the SwiftUI half of its presentation.
//  What it is called and how long it is are in `OpenHikesData`
//  (`Hike+Naming.swift`), beside the model.
//

import OpenHikesData
import SwiftUI

extension Hike {
    /// Full tint including the user's chosen alpha — used for the map polyline.
    var tint: Color { Color(hex: tintHex) ?? .green }

    /// The outline around the map polyline, with its alpha. Clear when unset
    /// or unreadable, which draws nothing.
    var routeBorder: Color { Color(hex: routeBorderHex) ?? .clear }

    /// A random, visually distinct route color, so each newly imported hike
    /// gets its own default tint instead of always green.
    ///
    /// The palette it comes out of is ``RouteTint``, which a community listing
    /// draws from too — by identity rather than by chance, since a listing has
    /// nowhere to keep the answer.
    nonisolated static func randomTintHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomTintHex(using: &generator)
    }

    /// The same tint, from a caller-supplied source of randomness — so a test
    /// that sweeps generated tints can seed it and reproduce a failure on
    /// exactly the hue that caused it.
    nonisolated static func randomTintHex<G: RandomNumberGenerator>(using generator: inout G) -> String {
        RouteTint.random(using: &generator).hexRGBA
    }

    /// Tint forced fully opaque — used everywhere except the map line (graph,
    /// list-row circle, header icon, highlight dot), so transparency reads only
    /// on the route itself.
    var tintOpaque: Color { tint.opaque }
}
