//
//  RouteTint.swift
//  OpenHikes
//
//  The one palette every route colour comes out of.
//
//  A hike imported from a file gets a colour at random so the library is not
//  a page of identical green lines — see ``Hike/randomTintHex()``, which is
//  where this lived. Community results had the same problem and the opposite
//  cause: nothing chose a colour for them at all, so every shared trail, every
//  curated one, every pin and every line was drawn in the app's own tint. A
//  search over a well-mapped valley came back as thirty green lines on top of
//  each other, which is the one thing the map is there to tell apart.
//
//  So the palette moves here and grows a second way in. Chance is right for a
//  hike the library is about to own: it happens once, the answer is stored in
//  ``Hike/tintHex``, and the hiker can change it afterwards. It is wrong for a
//  listing, which is a value fetched again on every search and owns nothing —
//  a colour drawn from chance would be a different colour each time the pins
//  were rebuilt, and the trail a hiker was following down the screen would
//  change colour under them. ``stable(for:)`` is the same palette addressed by
//  identity instead: the same listing is the same colour in the row, on the
//  pin, along the line and on its own screen, in this launch and the next.
//
//  Both roads end at ``color(hue:)``, and that is the point of the file. The
//  saturation and the brightness are fixed, so every hue this hands out is
//  legible against map tiles, against glass, and behind white glyph — which
//  is a property of the *palette* rather than of either caller, and was
//  previously enforced by two private constants only one of them could reach.
//

import SwiftUI

/// Where a route's colour comes from.
///
/// `nonisolated` for the reason ``Color/hexRGBA`` is: the callers include
/// `Hike`, whose SwiftData-generated members are nonisolated, and
/// ``CommunityListing``, which is a `Sendable` value type. Nothing here reads
/// a trait environment, so none of it needs the main actor.
nonisolated enum RouteTint {
    /// Fixed saturation and brightness, so every hue stays legible on the map
    /// and in the UI.
    ///
    /// These are what make a random hue safe to hand out unseen: at full
    /// saturation a yellow route vanishes into a sunlit tile, and at full
    /// brightness a white glyph on the pin has nothing to stand against.
    private static let saturation: Double = 0.65
    private static let brightness: Double = 0.85

    /// How finely ``stable(for:)`` divides the wheel.
    ///
    /// A tenth of a degree, which is far beyond telling apart by eye and is
    /// not meant to be told apart: it is the resolution the hash is reduced
    /// to, and a coarse one would make two unrelated trails collide far more
    /// often than the birthday bound on a page of twenty-five results.
    private static let hueSteps: UInt64 = 3600

    /// One colour of the palette.
    static func color(hue: Double) -> Color {
        Color(hue: hue, saturation: Self.saturation, brightness: Self.brightness)
    }

    /// A colour for something that is about to be stored — a hike being
    /// imported, recorded or drafted.
    ///
    /// The generator is a parameter so a test sweeping generated tints can
    /// seed it and reproduce a failure on exactly the hue that caused it.
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> Color {
        color(hue: .random(in: 0..<1, using: &generator))
    }

    /// A colour for something that is *not* stored, addressed by whatever
    /// identifies it.
    ///
    /// Deterministic across launches, processes and devices, which rules out
    /// `Hashable`: Swift seeds `hashValue` per process, so the obvious
    /// spelling would give the same trail a different colour every time the
    /// app started. FNV-1a over the key's UTF-8 is stable by construction, and
    /// its avalanche is more than enough to keep two listing ids that differ
    /// in their last digit — which is exactly what consecutive OSM relation
    /// ids look like — well apart on the wheel.
    static func stable(for key: String) -> Color {
        color(hue: Double(hash(key) % Self.hueSteps) / Double(Self.hueSteps))
    }

    /// FNV-1a, 64-bit. Wrapping arithmetic throughout, which is the algorithm
    /// rather than an accommodation of it.
    private static func hash(_ key: String) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash = offsetBasis
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
