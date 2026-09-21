//
//  MapCaptionNotice.swift
//  OpenHikes
//
//  One line under a pill on the map: what it says, the glyph beside it, and
//  whether that glyph is a warning.
//
//  Three fields, and the third is the one that matters. A search that came
//  back with nothing and a search that was refused are both "no results" and
//  are not the same thing to say: the first is an answer and the hiker should
//  look somewhere else, the second is a busy server and the hiker should wait.
//  ``CuratedTrailNotice`` exists to keep those apart under *Search this area*
//  on the Community tab, and ``TrailPointNotice`` keeps them apart under the
//  same pill in the trail maker.
//
//  This is the value the two of them have in common, so that
//  ``MapAreaSearchView`` can draw either without knowing which feature raised
//  it. It is deliberately not either of those enumerations: what the control
//  needs is a sentence and a glyph, and what each feature needs is its own
//  cases with its own words in them.
//
//  The same trio ``TrailLegNotice`` carries one folder over, and that one is
//  left where it is on purpose: it is drawn by a SwiftUI label inside a list
//  row rather than by this control, so folding them would couple a row in the
//  sheet to a pill on the map for the sake of three stored properties.
//

import Foundation

/// A caption under one of the map's own controls.
nonisolated struct MapCaptionNotice: Equatable, Sendable {
    let text: String
    /// An SF Symbol name, drawn at caption size beside the sentence.
    let symbolName: String
    /// Orange and a triangle, or neither — see this file's header.
    let isWarning: Bool
}
