//
//  SortMenu+Equatable.swift
//  OpenHikes
//
//  When a pass of the list the capsule stands over may rebuild it.
//
//  The capsule is handed the order as a `Binding`, which is new on every pass
//  of the body that makes it, and a binding is a dynamic property: so every
//  pass of the hikes list — a sheet drag, a save to any hike, a recording's
//  draft written — re-ran this body to draw the same capsule, as did every
//  pass of *Offline Maps*' list, a row chosen among them. Folded out of
//  `MapSheetHikes`, it ran on nearly every one of that list's passes. Both
//  lists apply `.equatable()`, so a copy that draws the same is the same
//  capsule.
//
//  The binding is compared by what it reads, the order in force, and is
//  otherwise left out, for the reason `MapSheetHikes` gives for its own
//  closures: what each setter writes to outlives any one copy of its list.
//  The hikes list's writes to `StoredSettings` and through its `@State` and
//  `@Query`; *Offline Maps*' to its ``OfflineCountriesListState``. What each
//  captures from its pass is the order in force, which this holds equal, and
//  whether the hand-made order is, which ``title`` and ``value`` say. So an
//  older binding does exactly what a newer one would.
//

import SwiftUI

extension SortMenu: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection
            && lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.identifier == rhs.identifier
            && lhs.label == rhs.label
            && lhs.options == rhs.options
    }
}
