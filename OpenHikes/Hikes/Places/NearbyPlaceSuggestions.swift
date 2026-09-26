//
//  NearbyPlaceSuggestions.swift
//  OpenHikes
//
//  What OpenStreetMap has mapped where the hiker is standing — the first thing
//  the recording screen's *Add Place* offers, before a place of their own.
//
//  A hiker who stops at a hut to mark it should get *the hut*: its name, its
//  kind, its height and its link, from the map, rather than a pin they type a
//  name into. So the sheet asks what is within ``matchRadiusMeters`` and
//  offers that first; *add my own* is the fallback for everything the map does
//  not have — the good bivouac rock, the ford that was up.
//
//  ## The device's store first, then the network, and neither may block
//
//  A hiker is usually somewhere the signal is poor. So what this device
//  already keeps near here — ``TrailPointSourcing/cachedPlaces(near:limit:)``,
//  filled by every earlier search — is offered at once, and a live answer
//  replaces it if one arrives. A refused or slow search leaves *add my own*
//  exactly as usable as it was; a place added then can be matched later from
//  nowhere but this sheet, which is the honest limit of doing it offline.
//

import Algorithms
import CoreLocation
import Foundation
import Observation
import OpenHikesData

nonisolated enum NearbyPlaceSuggestions {
    /// How close a mapped place must be to count as *here*.
    ///
    /// Wider than ``TrailPlaceAnchor/touchedOffRouteMeters``, because this is
    /// measured from where a hiker happens to be standing when they tap, which
    /// is the hut's terrace rather than the centre of its roof, or the far side
    /// of a summit cairn.
    static let matchRadiusMeters: Double = 150

    /// How many to offer. A short list: these are what is *here*.
    static let maximumSuggestions = 8

    /// The circle asked about.
    static func area(around coordinate: CLLocationCoordinate2D) -> CommunitySearchArea {
        CommunitySearchArea(coordinate: coordinate, radiusMeters: matchRadiusMeters)
    }

    /// Of `found`, one of each element within reach of `coordinate` that
    /// `held` does not already have, nearest first.
    ///
    /// *Already has* is the same OpenStreetMap element only, not the 25 m the
    /// other searches use: two different things a few metres apart — the hut
    /// and its spring — are exactly what a hiker standing between them wants
    /// to choose from.
    static func suggestions(
        from found: [TrailPlace],
        around coordinate: CLLocationCoordinate2D,
        excluding held: [TrailPlace]
    ) -> [TrailPlace] {
        let heldElements = Set(held.compactMap(\.osm).map(key))
        var seen: Set<String> = []
        return found
            .compactMap { place -> (place: TrailPlace, distance: Double)? in
                guard let osm = place.osm, !heldElements.contains(key(osm)),
                      seen.insert(key(osm)).inserted else { return nil }
                let distance = RouteGeometry.distanceMeters(from: coordinate, to: place.clCoordinate)
                guard distance <= matchRadiusMeters else { return nil }
                return (place, distance)
            }
            .min(count: maximumSuggestions) { $0.distance < $1.distance }
            .map(\.place)
    }

    private static func key(_ osm: TrailPlaceOSM) -> String {
        "\(osm.elementType)/\(osm.elementID)"
    }
}

/// One *Add Place*'s suggestions, for the sheet that shows them.
@MainActor
@Observable
final class NearbyPlaceFinder {
    /// What is offered now: the stored answer, then the live one.
    private(set) var suggestions: [TrailPlace] = []
    /// Whether the live search is still out.
    private(set) var isSearching = false
    /// Why the live search did not answer, if it did not.
    private(set) var outage: CuratedTrailOutage?

    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated deinit { /* intentionally empty */ }

    /// Asks what is around `coordinate`. Answers the search, which a test
    /// awaits rather than yielding until ``isSearching`` moves.
    @discardableResult func start(
        around coordinate: CLLocationCoordinate2D,
        excluding held: [TrailPlace],
        from source: any TrailPointSourcing
    ) -> Task<Void, Never> {
        task?.cancel()
        isSearching = true
        outage = nil
        let area = NearbyPlaceSuggestions.area(around: coordinate)
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let search = Task { [weak self] in
            let here = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let stored = await source.cachedPlaces(near: area, limit: TrailPointQuery.maximumStoredResults)
            guard let self, !Task.isCancelled else { return }
            suggestions = NearbyPlaceSuggestions.suggestions(from: stored, around: here, excluding: held)
            do {
                let live = try await source.places(near: area, showing: Set(TrailPlaceSymbol.allCases))
                guard !Task.isCancelled else { return }
                suggestions = NearbyPlaceSuggestions.suggestions(from: live, around: here, excluding: held)
            } catch {
                guard !Task.isCancelled else { return }
                outage = CuratedTrailOutage(error)
            }
            isSearching = false
        }
        task = search
        return search
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
