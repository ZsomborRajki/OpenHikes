//
//  RouteBorder.swift
//  OpenHikes
//
//  The outline a hike's line can carry in a colour of its own, around every
//  mark the line pattern makes: the stroke, each dash, each dot and each
//  chevron. Transparent unless the hiker picks a colour, which is how a hike
//  that never asked for one keeps drawing exactly as it did.
//
//  The geometry lives here rather than in the renderer for the reason
//  ``RouteLinePattern``'s does: the map and the pattern picker's swatches both
//  draw it, and one source keeps the swatch a preview of the route.
//
//  Both draw it the same way, *under* the marks it outlines: a ring stroked
//  round the outline of the line's own stroke — dashes, caps and all — and
//  each chevron stroked again, wider. That is what makes it an outline of the
//  whole silhouette: where a chevron's tails reach past the line, the border
//  follows them out and back, and where they sit on the line, the line covers
//  it.
//

import Foundation

nonisolated enum RouteBorder {
    /// How far the border reaches past each edge of a line `lineWidth` wide,
    /// in the units that width is in — the map scales the two together.
    ///
    /// A third of the width, so it grows with the width slider rather than
    /// becoming a hairline around a 12 pt line or swamping a 1 pt one — and
    /// never under a point, below which it stops reading as a border at all.
    static func width(forLineWidth lineWidth: Double) -> Double {
        max(lineWidth / widthDivisor, minimumWidth)
    }

    /// What a hike without a border stores: fully transparent.
    ///
    /// A mirror of the literal on ``Hike/routeBorderHex`` rather than the
    /// source of it, for the reason ``Hike/defaultTintHex`` is one: a mirrored
    /// CloudKit column's default has to be an inline literal.
    static let noneHex = "#00000000"

    /// What to store when the picker hands back `picked` over a border that is
    /// currently `current`, both as ``Color/hexRGBA`` writes them.
    ///
    /// The picker keeps its opacity when a colour is chosen — picking white
    /// onto a new hike hands back `#FFFFFF00` — and a border
    /// starts at none — so the first colour picked onto a hike would arrive as
    /// transparent as the nothing it replaced, and the tap would look ignored.
    /// A new colour picked while the border is invisible therefore comes in
    /// opaque. Only a new colour: dragging the opacity down to zero keeps the
    /// colour, and is left alone, because that is how a border is removed.
    static func pickedHex(_ picked: String, over current: String) -> String {
        guard picked.count == hexLength, current.count == hexLength,
              picked.hasSuffix(transparentAlpha), current.hasSuffix(transparentAlpha),
              picked.prefix(rgbPrefixLength) != current.prefix(rgbPrefixLength)
        else { return picked }
        return picked.prefix(rgbPrefixLength) + opaqueAlpha
    }

    /// "#RRGGBBAA", and the "#RRGGBB" in front of its alpha.
    private static let hexLength = 9
    private static let rgbPrefixLength = 7
    private static let transparentAlpha = "00"
    private static let opaqueAlpha = "FF"
    private static let widthDivisor: Double = 3
    private static let minimumWidth: Double = 1
}
