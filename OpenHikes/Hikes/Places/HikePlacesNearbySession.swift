//
//  HikePlacesNearbySession.swift
//  OpenHikes
//
//  *Places Nearby*, held where a turn of the phone cannot reach it.
//
//  The screen is drawn in the sheet in portrait and in the side panel in
//  landscape, so a turn builds it again. While this was the screen's own
//  state, the one built in the new host had found nothing and asked nothing:
//  the open card closed, the map was framed afresh, and the area was asked
//  about again (#1170). ``SheetPresentation`` keeps one of these for each
//  *Places Nearby* on the stack, as it keeps *Places Around Trail*'s
//  ``HikePlacesAroundSearch``, and lets it go when the screen is popped.
//

import CoreLocation
import Observation

@Observable
final class HikePlacesNearbySession {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// What has been found, and the card open on one of it.
    let search = HikePlacesAroundSearch()
    /// What the rows are measured from: the hiker as the screen opened, or
    /// the middle of the first search where there was no fix to read.
    var origin: CLLocationCoordinate2D?
    /// What has been asked, so switching a kind on asks that area again,
    /// *Try Again* has something to retry, and coming back to the screen asks
    /// nothing unless a search was cut off.
    var asked = PlacesNearbySearch()
}
