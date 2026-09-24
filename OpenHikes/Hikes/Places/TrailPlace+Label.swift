//
//  TrailPlace+Label.swift
//  OpenHikes
//
//  What a place and its kind are called on screen. The values are in
//  `OpenHikesData`; their words stay in the app, because only the app
//  target's build extracts strings into `Localizable.xcstrings` — a
//  `String(localized:)` in a package is looked up in the app's catalog but
//  never added to it.
//

import Foundation
import OpenHikesData

nonisolated extension TrailPlaceSymbol {
    /// The word, which is also what an unnamed place is called.
    ///
    /// Separate from ``rawValue`` even where the two currently read the same,
    /// because one of them is a lookup key in somebody else's symbol table and
    /// the other is a sentence in the hiker's language. Translating the raw
    /// value would silently rewrite every stored row and every exported file.
    var label: String {
        switch self {
        case .viewpoint: String(localized: "Viewpoint")
        case .water: String(localized: "Water")
        case .shelter: String(localized: "Shelter")
        case .junction: String(localized: "Junction")
        case .parking: String(localized: "Parking")
        case .summit: String(localized: "Summit")
        case .camp: String(localized: "Camp")
        case .caution: String(localized: "Caution")
        }
    }
}

nonisolated extension TrailPlace {
    /// What this place is called on screen: its name, or the word for what it
    /// is, or simply *Place*.
    ///
    /// The fallback chain rather than an empty label, because unnamed is the
    /// normal case and a row of blanks is unreadable — a waterfall, a spring
    /// and a viewpoint mostly have no name at all, which is the measurement
    /// the plan issue makes against OpenStreetMap and the reason a place is
    /// built from a symbol and a distance rather than from a name.
    var displayName: String {
        if !name.isEmpty { return name }
        return symbol?.label ?? String(localized: "Place")
    }
}
