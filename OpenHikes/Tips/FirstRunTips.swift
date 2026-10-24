//
//  FirstRunTips.swift
//  OpenHikes
//
//  The six first-run tips' words and glyphs. Which of them shows, and when, is
//  ``AppTips``'s business, and where is the business of the screen each one
//  is drawn on. Each tip says what its control does and nothing about where
//  the control is, because it is drawn beside it; and each carries that
//  control's own glyph, so the two read as one thing.
//
//  Every `id` is spelled out rather than left to TipKit, which defaults it to
//  the type's name. The id is what a tip's status is stored against, so a type
//  renamed in a refactor would show its tip again to everybody who had already
//  closed it. `FirstRunTipsTests` pins them.
//

import SwiftUI
import TipKit

/// A tip drawn on the map, whose words the map has to be able to say itself.
///
/// MapKit builds the map's accessibility by walking the UIKit views on it, and
/// TipKit draws a card's words in SwiftUI inside one — so a card on the map
/// was not there at all for VoiceOver, or for automation. Its words are kept
/// here as well as in `title` and `message`, for ``MapTipCardView`` to say.
nonisolated protocol MapTip: Tip {
    static var titleWords: LocalizedStringResource { get }
    static var messageWords: LocalizedStringResource { get }
}

/// *Record a hike*: the lower button of the pill on the map's leading edge.
nonisolated struct RecordHikeTip: MapTip {
    static let tipID = "record-hike"
    static let titleWords: LocalizedStringResource = "Record a Hike"
    static let messageWords: LocalizedStringResource =
        "Track your hike with GPS. It keeps recording while your phone is locked."

    var id: String { Self.tipID }
    var title: Text { Text(Self.titleWords) }
    var message: Text? { Text(Self.messageWords) }
    var image: Image? { Image(systemName: MapTrailDraftControlsView.recordSymbolName) }
}

/// *Make a trail*: the upper button of the same pill.
nonisolated struct MakeTrailTip: MapTip {
    static let tipID = "make-trail"
    static let titleWords: LocalizedStringResource = "Make a Trail"
    static let messageWords: LocalizedStringResource =
        "Plan a route before you go. Pick a start and a destination, and it follows the paths between them."

    var id: String { Self.tipID }
    var title: Text { Text(Self.titleWords) }
    var message: Text? { Text(Self.messageWords) }
    var image: Image? { Image(systemName: MapTrailDraftControlsView.symbolName) }
}

/// The *Community* half of the sheet's list picker.
nonisolated struct CommunityTabTip: Tip {
    static let tipID = "community-tab"

    var id: String { Self.tipID }
    var title: Text { Text("Find Trails") }
    var message: Text? {
        Text("Community shows hikes other people shared, and OpenStreetMap trails, for the area on the map.")
    }
    var image: Image? { Image(systemName: "figure.hiking") }
}

/// *Search this area*, the *Community* tab's pill at the top of the map.
nonisolated struct SearchThisAreaTip: MapTip {
    static let tipID = "search-this-area"
    static let titleWords: LocalizedStringResource = "Search Somewhere Else"
    static let messageWords: LocalizedStringResource = "Move the map, then tap here to find trails in the new area."

    var id: String { Self.tipID }
    var title: Text { Text(Self.titleWords) }
    var message: Text? { Text(Self.messageWords) }
    var image: Image? { Image(systemName: MapAreaSearchView.symbolName) }
}

/// *Add Place*, in the recording screen's bar.
nonisolated struct AddPlaceTip: Tip {
    static let tipID = "recording-add-place"

    var id: String { Self.tipID }
    var title: Text { Text("Mark a Place") }
    var message: Text? {
        Text("Save the viewpoint, shelter or water you’re standing at, and add photos to it.")
    }
    var image: Image? { Image(systemName: RecordingPlaceSymbols.addPlace) }
}

/// *Places Nearby*, beside *Add Place*.
nonisolated struct PlacesNearbyTip: Tip {
    static let tipID = "recording-places-nearby"

    var id: String { Self.tipID }
    var title: Text { Text("What’s Around You") }
    var message: Text? {
        Text("See the viewpoints, shelters and water OpenStreetMap has mapped nearby, and add them to this hike.")
    }
    var image: Image? { Image(systemName: RecordingPlaceSymbols.placesNearby) }
}
