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
//  Both draw it the same way, *under* the marks it outlines: the line again,
//  wider, with each dash lengthened to match — then the line's own stroke
//  cleared out of it, so what is left is a ring and a translucent line shows
//  the map through it rather than the border — and each chevron stroked
//  again, wider. That is what makes it an outline of the whole silhouette:
//  where a chevron's tails reach past the line, the border follows them out
//  and back, and where they sit on the line, the line covers it.
//
//  A wider copy of the line, not a ring traced round its outline, because the
//  outline is what MapKit never has to build. The first version of this asked
//  Core Graphics for it, and on a 10,000-point route seen whole a single tile
//  took five seconds: the outline of a line far wider than the gaps between
//  its points is thousands of overlapping pieces. A wider copy is stroked as
//  cheaply as the line itself.
//

import CoreGraphics
import Foundation

nonisolated public enum RouteBorder {
    /// How far the border reaches past each edge of a line `lineWidth` wide,
    /// in the units that width is in — the map scales the two together.
    ///
    /// A third of the width, so it grows with the width slider rather than
    /// becoming a hairline around a 12 pt line or swamping a 1 pt one — and
    /// never under a point, below which it stops reading as a border at all.
    public static func width(forLineWidth lineWidth: Double) -> Double {
        max(lineWidth / widthDivisor, minimumWidth)
    }

    /// What a hike that has never had a border picked stores: no colour at
    /// all, which draws as clear.
    ///
    /// Empty rather than a transparent colour, because every transparent
    /// colour is one the picker can hand back — `#00000000` is black at the
    /// opacity a new hike starts at — and ``pickedHex(_:over:)`` has to tell a
    /// first pick of black apart from the value already there.
    ///
    /// A mirror of the literal on ``Hike/routeBorderHex`` rather than the
    /// source of it, for the reason ``Hike/defaultTintHex`` is one: a mirrored
    /// CloudKit column's default has to be an inline literal.
    public static let noneHex = ""

    /// What to store when the picker hands back `picked` over a border that is
    /// currently `current`, both as ``Color/hexRGBA`` writes them.
    ///
    /// The picker keeps its opacity when a colour is chosen — picking white
    /// onto a new hike hands back `#FFFFFF00` — and a border
    /// starts at none — so the first colour picked onto a hike would arrive as
    /// transparent as the nothing it replaced, and the tap would look ignored.
    /// A colour picked while the border is invisible therefore comes in
    /// opaque: any colour onto a hike that never had one, and a *different*
    /// colour onto one faded out. Dragging the opacity down to zero keeps the
    /// colour, and is left alone, because that is how a border is removed.
    public static func pickedHex(_ picked: String, over current: String) -> String {
        guard picked.count == hexLength, picked.hasSuffix(transparentAlpha) else { return picked }
        let firstPick = current == noneHex
        let newColourOverFaded = current.count == hexLength && current.hasSuffix(transparentAlpha)
            && picked.prefix(rgbPrefixLength) != current.prefix(rgbPrefixLength)
        guard firstPick || newColourOverFaded else { return picked }
        return picked.prefix(rgbPrefixLength) + opaqueAlpha
    }

    /// The dash pattern for the border's wider copy of a line dashed
    /// `dashes` — in the units the dashes are in — with `cap` at each end.
    ///
    /// A round cap already grows with the stroke, so a wider dot is a dot with
    /// a border round it and the pattern stands. A butt cap does not: the
    /// wider dash would stop exactly where the line's dash stops and leave its
    /// ends bare. So each dash is lengthened by the border at both ends, its
    /// gap shortened to keep the period, and the whole pattern started a
    /// border early — which is what `phase` is, in the stroke's own dash
    /// phase terms.
    public static func dashes(
        outlining dashes: [Double],
        cap: CGLineCap,
        borderWidth: Double
    ) -> (lengths: [Double], phase: Double) {
        guard cap == .butt, dashes.count == 2 else { return (dashes, 0) }
        let reach = borderWidth * 2
        // A gap narrower than the border would close; keep a sliver of it
        // rather than hand Core Graphics a zero or negative length.
        return ([dashes[0] + reach, max(dashes[1] - reach, minimumGap)], borderWidth)
    }

    /// "#RRGGBBAA", and the "#RRGGBB" in front of its alpha.
    private static let hexLength = 9
    private static let rgbPrefixLength = 7
    private static let transparentAlpha = "00"
    private static let opaqueAlpha = "FF"
    private static let widthDivisor: Double = 3
    private static let minimumWidth: Double = 1
    private static let minimumGap: Double = 0.1
}
