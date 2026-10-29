//
//  CommunityBrowser+HandOrder.swift
//  OpenHikes
//
//  The order the hiker dragged community rows into, applied to a section.
//
//  Beside ``CommunityBrowser/handOrder`` rather than in the sheet that draws
//  the rows: the order belongs to the object that owns the results, and a
//  rule that lives here can be asserted without building a list.
//

import Foundation

extension CommunityBrowser {
    /// `listings` with the hand-ordered rows first, in the order they were put.
    /// Why that order is kept in memory, and for how long, is
    /// ``handOrder``'s to say.
    ///
    /// A listing nobody has moved has no entry and keeps the place the search
    /// gave it, after everything that was placed by hand. That relies on
    /// `sorted(by:)` being stable, which the standard library guarantees: the
    /// unmoved rows all sort as `Int.max`, so they tie and keep their order.
    func arranged(_ listings: [CommunityListing]) -> [CommunityListing] {
        guard !handOrder.isEmpty else { return listings }
        return listings.sorted { first, second in
            (handOrder[first.id] ?? Int.max) < (handOrder[second.id] ?? Int.max)
        }
    }
}
