//
//  MapCommunityAnnotations.swift
//  OpenHikes
//
//  Where the shared hikes in the list actually are.
//
//  This is the half of the feature that was missing. The nearby query is
//  driven entirely by the map — ``CommunityBrowser`` takes a region and asks
//  about a circle of it — and until now its answer was a list of names in a
//  sheet drawn over the map that asked the question. A hiker could see that
//  eleven hikes were near here and nothing at all about *where* near here, so
//  the one input the feature takes had no output anywhere near it.
//
//  A marker per listing closes that loop. It also makes the two halves of the
//  section point at each other: the rows and the pins are the same twenty-five
//  listings, a tap on either opens the same preview, and a hiker who pans
//  away can see the pins leave the screen — which is the most direct possible
//  statement of what *Search this area* is for.
//
//  Built out of MapKit's own pieces for the reason ``PhotoMapAnnotation`` is:
//  `MKMarkerAnnotationView` already draws the balloon, the shadow, the drop,
//  the selection growth and the decluttering, and its callout already draws
//  the card, the title and the subtitle. What is app-specific here is a glyph,
//  two lines of text and where the tap goes.
//
//  Unlike the photo pins, these are allowed to declutter. A hike is one of a
//  page of results rather than a place the hiker asked to be shown, two
//  trailheads in one valley can sit on top of each other, and a map that
//  hides the pin underneath is telling the truth about a list the hiker can
//  still scroll.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One published hike, in the shape MapKit wants it.
final class CommunityMapAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "communityHikePin"

    let listing: CommunityListing
    @objc dynamic let coordinate: CLLocationCoordinate2D
    @objc let title: String?
    /// The same line the row carries, minus the photo count the callout has
    /// no room for: a distance and a credit are what decide whether this is
    /// worth opening.
    @objc let subtitle: String?

    init(listing: CommunityListing) {
        self.listing = listing
        coordinate = listing.coordinate
        title = listing.title
        subtitle = Self.calloutSubtitle(for: listing)
        super.init()
    }

    /// "8.0 km · by Anna", with the credit left out rather than rendered
    /// empty when nobody typed one.
    private static func calloutSubtitle(for listing: CommunityListing) -> String {
        let distance = Measurement(value: listing.distanceMeters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        guard !listing.authorName.isEmpty else { return distance }
        return String(localized: "\(distance) · by \(listing.authorName)")
    }
}

// MARK: - Community pins on the map

extension MapView.Coordinator {
    /// Observes the listings the browser is showing and applies them
    /// imperatively, then re-registers — the same arrangement
    /// ``observePhotoPins(_:on:)`` uses, so a nearby answer landing redraws
    /// MapKit's annotations and no SwiftUI view.
    ///
    /// Idempotent, like every other registration here: `withObservationTracking`
    /// offers no way to cancel one, so a second would leave two observers
    /// rebuilding the same annotations forever.
    func observeCommunityPins(_ browser: CommunityBrowser, on mapView: MKMapView) {
        guard !isObservingCommunityPins else { return }
        isObservingCommunityPins = true
        trackCommunityPins(browser, on: mapView)
    }

    private func trackCommunityPins(_ browser: CommunityBrowser, on mapView: MKMapView) {
        applyCommunityPins(browser.nearbyListings, on: mapView)
        withObservationTracking {
            _ = browser.nearbyListings
        } onChange: { [weak self, weak mapView, weak browser] in
            let coordinator = self
            let map = mapView
            let model = browser
            Task { @MainActor in
                guard let coordinator, let map, let model else { return }
                coordinator.trackCommunityPins(model, on: map)
            }
        }
    }

    /// Rebuilds the pins wholesale rather than diffing them.
    ///
    /// At most ``CommunityBrowser``'s result limit of them, and this runs when
    /// a request lands or a block hides somebody — never at drag or fix
    /// frequency. The guard is what keeps a republish of the same listings
    /// from dropping and re-dropping every marker on the map.
    func applyCommunityPins(_ listings: [CommunityListing], on mapView: MKMapView) {
        guard communityAnnotations.map(\.listing) != listings else { return }
        RenderSignpost.mark("MapCommunityPinsRebuilt", "\(listings.count) pins")
        if !communityAnnotations.isEmpty {
            mapView.removeAnnotations(communityAnnotations)
            communityAnnotations = []
        }
        guard !listings.isEmpty else { return }
        let annotations = listings.map(CommunityMapAnnotation.init)
        communityAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// A marker in the app's tint with a hiker in it, and the hike's name in
    /// the callout MapKit draws for it.
    ///
    /// Deliberately not the route tint the photo pins take: that colour
    /// belongs to the hiker's own selected hike, which may well be drawn on
    /// the same screen, and somebody else's published trail is not it.
    func communityAnnotationView(
        for annotation: CommunityMapAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = CommunityMapAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = true
        #if os(iOS)
        view.glyphImage = UIImage(systemName: "figure.hiking")
        view.markerTintColor = .tintColor
        view.rightCalloutAccessoryView = Self.calloutDisclosure()
        #endif
        // Allowed to be hidden by a neighbour — see this file's header.
        view.displayPriority = .defaultHigh
        // MapKit would otherwise speak the title alone, which says nothing
        // about what kind of thing is standing on the map.
        view.accessibilityLabel = Self.markerLabel(for: annotation.listing)
        view.accessibilityIdentifier = "community-hike-pin"
        return view
    }

    /// What the marker says, as distinct from the callout that opens from it.
    private static func markerLabel(for listing: CommunityListing) -> String {
        String(localized: "Community hike, \(listing.title)")
    }

    #if os(iOS)
    /// The way in from a callout.
    ///
    /// An accessory button rather than a tap on the callout itself, which is
    /// what MapKit documents and the only part of a callout that reports a
    /// tap. `calloutAccessoryControlTapped` in `MapCoordinator.swift` is where
    /// it lands.
    private static func calloutDisclosure() -> UIButton {
        let button = UIButton(type: .detailDisclosure)
        button.accessibilityLabel = String(localized: "Open this community hike")
        button.accessibilityIdentifier = "community-pin-open"
        return button
    }
    #endif
}
