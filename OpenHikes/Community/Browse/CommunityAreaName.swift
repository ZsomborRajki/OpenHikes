//
//  CommunityAreaName.swift
//  OpenHikes
//
//  What to call the circle of map a nearby answer came from.
//
//  The list used to be headed *Nearby*, which names the query rather than the
//  place: a hiker who panned to the next valley, or who opened the app
//  somewhere they were not yesterday, had no way to tell from the list which
//  "here" it meant. A place name is the one thing that says so in the two
//  words the header has room for — *near Esztergom* — and it is also what
//  makes ``CommunityBrowser/searchVisibleArea()`` legible after the fact:
//  the button says *Search this area* and the header says which area it was.
//
//  ## Why this is a seam
//
//  For the reason every injected transport in this repository is one — see
//  *Deliberate test seams* in the instructions. This one reaches the network,
//  so a suite that used the real thing would geocode from a test run, on
//  somebody's rate limit, and get a different answer depending on where the
//  machine is. ``OpenHikesModel`` hands the browser `nil` for exactly the
//  launches it hands it a `nil` transport, and a browser without one heads
//  its list with the plain *Community Hikes* it had before.
//
//  ## Why it is main-actor rather than `@concurrent`
//
//  Unlike ``CommunityTransporting``, whose requirements are `@concurrent`
//  because a conformance could otherwise block the caller, this one cannot
//  choose: `MKReverseGeocodingRequest.mapItems` is declared `NS_SWIFT_UI_ACTOR`
//  in the SDK, so MapKit delivers its answer on the main actor whatever the
//  caller does. The work itself is a round trip in another process; what
//  arrives here is a string.
//

import CoreLocation
import Foundation
import MapKit
import os

/// Turns a searched area into something to call it.
@MainActor
protocol CommunityAreaNaming: AnyObject {
    /// The place `area` is centred on, or `nil` when there is nothing to call
    /// it. A name is a nicety, so every failure — no network, no result, a
    /// cancelled request — is the same answer.
    func name(for area: CommunitySearchArea) async -> String?
}

/// MapKit's own answer, which is the same one the search field's suggestions
/// come from.
@MainActor
final class GeocodedAreaNames: CommunityAreaNaming {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// The last request, cancelled when another is made.
    ///
    /// One at a time because there is only ever one header: a hiker who
    /// takes two offers in quick succession wants the second name, and the
    /// first request's answer would otherwise be free to land after it.
    private var request: MKReverseGeocodingRequest?

    func name(for area: CommunitySearchArea) async -> String? {
        request?.cancel()
        let location = CLLocation(latitude: area.latitude, longitude: area.longitude)
        guard let pending = MKReverseGeocodingRequest(location: location) else { return nil }
        request = pending
        do {
            let items = try await pending.mapItems
            guard request === pending else { return nil }
            request = nil
            // The city rather than the full address, and the item's own name
            // only where there is no city to give: a header has room for a
            // place, and a street is a smaller thing than the circle this
            // describes.
            return items.first.flatMap { item in
                item.addressRepresentations?.cityName ?? item.name
            }
        } catch {
            // Logged and no more, exactly as a failed title search is. A
            // header that says *Community Hikes* instead of *Community Hikes near
            // Esztergom* is not something the hiker can act on, and there is
            // nowhere on screen that a geocode belongs.
            Self.logger.debug(
                "Naming a searched area failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
