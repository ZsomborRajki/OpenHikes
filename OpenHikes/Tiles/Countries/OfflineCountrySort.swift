//
//  OfflineCountrySort.swift
//  OpenHikes
//
//  The orders *Offline Maps* can be put in: by how near an area is to the
//  hiker, by name, or by what it takes to download.
//
//  *Nearest* is the order the list opens in wherever the hiker's position is
//  known, because the area a hiker wants is nearly always the one they are in
//  or the one next to it. Without a position there is nothing to measure
//  from, so the order is not offered and the list opens by name. The choice
//  lasts as long as the list is up: each visit opens on the order that suits
//  where the hiker is, rather than on what was last picked somewhere else.
//
//  What each order does to the list is ``OfflineCountryDirectory``'s.
//

import Foundation

enum OfflineCountrySort: Hashable {
    case largest
    case name
    case nearest

    /// The orders to offer, the one the list opens in first.
    static func offered(hasPosition: Bool) -> [Self] {
        hasPosition ? [.nearest, .name, .largest] : [.name, .largest]
    }

    /// The order the list is in: the hiker's choice where it is offered, and
    /// otherwise the one it opens in.
    static func inForce(chosen: Self?, hasPosition: Bool) -> Self {
        if let chosen, chosen != .nearest || hasPosition { return chosen }
        return hasPosition ? .nearest : .name
    }

    /// What the menu says, phrased as the answer rather than the field, as
    /// the hikes list's orders are.
    var title: String {
        switch self {
        case .nearest: String(localized: "Nearest")
        case .name: String(localized: "Name")
        case .largest: String(localized: "Largest")
        }
    }

    var symbol: String {
        switch self {
        case .nearest: "location"
        case .name: "textformat.abc"
        case .largest: "internaldrive"
        }
    }
}
