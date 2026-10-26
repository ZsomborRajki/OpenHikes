//
//  RecordingPlaceName.swift
//  OpenHikes
//
//  What to call the town a recording started in.
//
//  The question ``HikeRecorder`` asks once per walk, about its first point —
//  see ``HikeRecorder/nameStartPlace(at:)`` for when it asks and what the
//  answer names. This file is only the asking.
//
//  ## The city, and nothing cleverer
//
//  MapKit's city — `cityName` on iOS 26 and later, Core Location's `locality`
//  below, both read through ``ReverseGeocode`` — which is the word the
//  forecast's sheet is headed with too. Not the street, the summit or the
//  postcode a stop in the trail maker is read from (``TrailStopName``): those
//  name a spot, and a walk is kilometers of spots.
//
//  Nor is the answer held to a distance, as a stop's is. An answer about the
//  area a spot is in, standing kilometers from it, is exactly what is being
//  asked for here. Measured on 2026-10-26 with the request the app makes:
//  central Budapest and the Buda hills both came back as "Budapest", forest
//  above Pilisszentkereszt as "Pilisszentkereszt" from an answer 1.2 km off,
//  the Börzsöny as its municipality, "Szokolya", from 12 km off, the forest
//  under the Traunstein as "Gmunden", and the Yosemite backcountry as
//  "Yosemite National Park". MapKit nearly always has something to say — the
//  middle of the Sahara came back as its governorate — so the time-of-day
//  name is mostly what a failed lookup leaves: a trailhead with no signal.
//
//  ## Why this is a seam
//
//  For the reason ``WeatherPlaceNaming`` and ``CommunityAreaNaming`` are — see
//  *Deliberate test seams* in `AGENTS.md`. It reaches the network, so a suite
//  using the real thing would geocode from a test run and assert on whichever
//  town the runner's simulated coordinate falls in. The composition root hands
//  the recorder `nil` under tests, and a recorder without a namer names its
//  walks exactly as it did before this file existed.
//
//  ## Why it is main-actor rather than `@concurrent`
//
//  For the reason those two are: `MKReverseGeocodingRequest.mapItems` is
//  declared `NS_SWIFT_UI_ACTOR`, and below iOS 26 `CLGeocoder` calls back on
//  the main thread. The work is a round trip in another process; what arrives
//  here is a string.
//

import CoreLocation
import Foundation
import MapKit
import os

/// Turns the coordinate a recording started at into the town it started in.
@MainActor
protocol RecordingPlaceNaming {
    /// The city `coordinate` falls in, or `nil` when there is nothing to call
    /// it. A name is a nicety, so every failure — no network, no result, a
    /// refused request — is the same answer.
    func cityName(at coordinate: CLLocationCoordinate2D) async -> String?
}

/// MapKit's own answer, the one the forecast's sheet is headed with.
@MainActor
struct GeocodedRecordingPlaceNames: RecordingPlaceNaming {
    private static let logger = Logger(subsystem: "OpenHikes", category: "HikeRecorder")

    func cityName(at coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = ReverseGeocode(location: location) else { return nil }
        do {
            return try await request.mapItems.first?.cityName
        } catch {
            // Logged and no more. A walk named for the time of day rather than
            // for its town is not something the hiker can act on, and the
            // name it falls back to is the one every recording used to have.
            Self.logger.debug(
                "Naming where a recording started failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
