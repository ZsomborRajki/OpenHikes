//
//  ReverseGeocode.swift
//  OpenHikes
//
//  *What is here*, asked of MapKit on every release the app supports, and
//  what an answer says, read the same way on each.
//
//  Three things ask: the trail maker naming a tapped stop, the community
//  list's header naming the searched area, and the forecast naming its place.
//  On iOS 26 and later they ask `MKReverseGeocodingRequest` and read the
//  answer's `MKAddress`, `addressRepresentations` and `location`. None of
//  those exist below 26, so there the question goes to `CLGeocoder` — which
//  26 deprecates for exactly this replacement, and which is only reached
//  below it — and the answer comes back as a placemark wrapped in an
//  `MKMapItem`, read through `MKMapItem.placemark`.
//
//  The two answers are not the same shape, measured side by side on
//  2026-10-25 for the pins `TrailStopNameTests` records. The city is the
//  same word in both: `locality` below, `cityName` above. The location is
//  not: MapKit places an area answer at the area's middle, 1.8 km from a pin
//  in the forest above the Traunsee, and Core Location places every answer at
//  the pin itself. ``TrailStopName`` reads the difference; nothing else here
//  has to.
//

import Contacts
import CoreLocation
import MapKit

/// One reverse geocode, which its holder can cancel and tell apart from a
/// later one by identity.
@MainActor
final class ReverseGeocode {
    private let location: CLLocation
    /// `MKReverseGeocodingRequest` on iOS 26 and later, `CLGeocoder` below.
    private let request: AnyObject

    /// `nil` for a location MapKit will not accept — the same refusal
    /// `MKLocalSearch` makes of a region that is not a place.
    init?(location: CLLocation) {
        if #available(iOS 26.0, *) {
            guard let mapKitRequest = MKReverseGeocodingRequest(location: location) else { return nil }
            request = mapKitRequest
        } else {
            guard CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
            request = CLGeocoder()
        }
        self.location = location
    }

    /// What MapKit knows about the location, best answer first.
    var mapItems: [MKMapItem] {
        get async throws {
            if #available(iOS 26.0, *), let mapKitRequest = request as? MKReverseGeocodingRequest {
                return try await mapKitRequest.mapItems
            }
            guard let geocoder = request as? CLGeocoder else { return [] }
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks.map { placemark in
                let item = MKMapItem(placemark: MKPlacemark(placemark: placemark))
                // A map item made from a placemark has no zone of its own,
                // and the forecast reads its days in this one.
                item.timeZone = placemark.timeZone
                return item
            }
        }
    }

    func cancel() {
        if #available(iOS 26.0, *), let mapKitRequest = request as? MKReverseGeocodingRequest {
            mapKitRequest.cancel()
        } else {
            (request as? CLGeocoder)?.cancelGeocode()
        }
    }
}

nonisolated extension MKMapItem {
    /// A map item standing at `coordinate` with no address: the two ends of a
    /// leg handed to `MKDirections`.
    static func standing(at coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26.0, *) {
            return MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: nil
            )
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    /// Where the item stands.
    var standingLocation: CLLocation {
        if #available(iOS 26.0, *) {
            return location
        }
        return placemark.location ?? CLLocation(
            latitude: placemark.coordinate.latitude,
            longitude: placemark.coordinate.longitude
        )
    }

    /// The city the item is in.
    var cityName: String? {
        if #available(iOS 26.0, *) {
            return addressRepresentations?.cityName
        }
        return placemark.locality
    }

    /// MapKit's short address, as it gives it.
    ///
    /// Below 26 there is none to give, so it is the placemark's own name or
    /// the thing of interest it stands at, then its locality.
    var shortAddressLine: String? {
        if #available(iOS 26.0, *) {
            return address?.shortAddress
        }
        return Self.joined([placemark.areasOfInterest?.first ?? placemark.name, placemark.locality])
    }

    /// MapKit's whole address.
    ///
    /// Below 26 it is the postal address as the region writes one, led by the
    /// thing of interest the placemark stands at — the summit — which a postal
    /// address leaves out and MapKit's own puts first.
    var fullAddressLine: String? {
        if #available(iOS 26.0, *) {
            return address?.fullAddress
        }
        let postal = placemark.postalAddress.map { address in
            CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
                .split(whereSeparator: \.isNewline)
                .joined(separator: ", ")
        }
        let feature = placemark.areasOfInterest?.first
        if let feature, let postal, postal.contains(feature) {
            return postal
        }
        return Self.joined([feature, postal])
    }

    /// The parts that have anything in them, in order and once each.
    private static func joined(_ parts: [String?]) -> String? {
        var kept: [String] = []
        for part in parts.compactMap({ $0?.trimmingCharacters(in: .whitespaces) })
        where !part.isEmpty && !kept.contains(part) {
            kept.append(part)
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }
}
