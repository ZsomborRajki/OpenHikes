//
//  CommunityListing+Presentation.swift
//  OpenHikes
//
//  The colour a shared hike is drawn in, everywhere it is drawn.
//
//  Here rather than on ``CommunityListing`` itself for the reason
//  ``Hike+Presentation`` is beside `Hike`: the payload types are what comes
//  off CloudKit and out of Overpass, and they are Foundation-only. A `Color`
//  is not part of what a listing *is*.
//

import OpenHikesData
import SwiftUI

nonisolated extension CommunityListing {
    /// This listing's own colour: the row's circle, the pin on the map, the
    /// line under it, and the graph on the screen that opens from either.
    ///
    /// Every one of those used to be the app's tint, on the argument that a
    /// route colour belongs to a hike the hiker owns and a stranger's trail is
    /// not one. That argument holds for a single listing and falls apart at
    /// twenty-five of them: a search over a well-mapped valley drew a page of
    /// rows with identical circles over a map of identical lines crossing each
    /// other, so the question a map full of trails exists to answer — *which
    /// of these is the one I was just reading about* — had no answer anywhere
    /// on it. Colour is the only channel left, because the pins have already
    /// spent their glyph on saying trail-or-photograph and their subtitle on
    /// saying how long the walk is.
    ///
    /// What keeps these from being mistaken for the hiker's own route is not
    /// the colour and never really was: it is that they are drawn thinner, at
    /// half strength, and underneath it. See ``MapCommunityRoutes``.
    ///
    /// Derived from ``CommunityListing/id`` rather than stored, because there
    /// is nowhere to store it — a listing is a value fetched again by every
    /// search, and a colour that came from chance would change under a hiker
    /// each time the pins were rebuilt. The id is the right key beyond being
    /// the available one: it is the same string ``Hike/importedFromListingID``
    /// keeps, which is what lets an import carry this exact colour into the
    /// library rather than landing a trail the hiker has been following in
    /// purple as another green line. See ``CommunityImport``.
    var tint: Color { RouteTint.stable(for: id) }

    /// The same colour in the form ``Hike/tintHex`` stores, for the import
    /// that turns this listing into a hike.
    ///
    /// Spelled here rather than at the call site so that ``CommunityImport``
    /// stays clear of SwiftUI, which is the line every payload-side file in
    /// this folder keeps.
    var tintHex: String { tint.hexRGBA }
}
