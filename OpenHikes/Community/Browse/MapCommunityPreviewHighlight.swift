//
//  MapCommunityPreviewHighlight.swift
//  OpenHikes
//
//  Where on a stranger's trail its elevation chart is pointing.
//
//  A hike of the hiker's own has always had this: scrubbing its chart moves a
//  dot along its line on the map, so a climb on the graph is a slope they can
//  find on the ground. The community preview draws the same chart — see
//  ``CommunityHikeView`` — and its scrub moved the chart's own marker and
//  nothing else. Dragging to the steep stretch in the middle said how steep
//  and never where, over a map that was drawing that very route at full
//  strength behind the sheet. So the dot stands on that line now.
//
//  ## Its own dot, not the hike's
//
//  ``RouteHighlight``'s dot belongs to the hiker's selected route and is drawn
//  in the colour they chose for it, and a hike's own screen can sit under a
//  preview pushed over it with its dot still standing on its line. So the
//  preview's is a second annotation, drawn in the listing's own colour — the
//  colour of the line it stands on and of the chart it mirrors — and it is
//  ``CommunityBrowser``'s, held beside the previewed line: the calls that put
//  that line on the map and take it off retire this too. See
//  ``CommunityBrowser/previewScrubbed(to:of:)``.
//
//  The view is the hike's dot exactly, colour aside — see
//  ``MapView/Coordinator/highlightDotView(for:tint:reuseIdentifier:on:)`` —
//  and like the hike's it is moved rather than replaced while a finger drags
//  it, because adding and removing an annotation per sample would churn
//  MapKit's views at drag frequency.
//

import MapKit
import SwiftUI

/// The dot on the open preview's line, in the shape MapKit wants it.
///
/// Its own class rather than an `MKPointAnnotation`, because the map tells
/// the two dots apart by class: the hike's is drawn in the route tint, and
/// this one in the colour of the listing whose line it stands on.
final class CommunityPreviewHighlightAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "communityPreviewHighlight"

    /// The preview this dot is for. A dot left standing for one hike is
    /// replaced rather than moved when the next one's chart is touched,
    /// because moving it would carry the first hike's colour onto the second
    /// hike's line.
    let listingID: String
    /// The listing's own colour — its line's and its chart's.
    let tint: Color
    /// `var` and `dynamic` because MapKit observes it: the dot follows a
    /// finger by moving, not by being taken off the map and put back.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`. Neither is drawn.
    @objc let title: String? = nil
    @objc let subtitle: String? = nil

    init(listing: CommunityListing, coordinate: CLLocationCoordinate2D) {
        listingID = listing.id
        tint = listing.tint
        self.coordinate = coordinate
        super.init()
    }
}

extension MapView.Coordinator {
    /// Observes where the open preview's chart is pointing and applies it,
    /// then re-registers — the loop every other layer on this map runs, so a
    /// finger on a stranger's chart moves MapKit and no SwiftUI view.
    ///
    /// Started from ``observeCommunityRoutes(_:on:)`` and under its flag: the
    /// dot is a point on one of those lines.
    func trackCommunityPreviewHighlight(_ browser: CommunityBrowser, on mapView: MKMapView) {
        applyCommunityPreviewHighlight(browser.previewHighlight, on: mapView)
        reobserving(self, mapView, browser) {
            _ = browser.previewHighlight
        } onChange: { coordinator, map, model in
            coordinator.trackCommunityPreviewHighlight(model, on: map)
        }
    }

    /// Adds, moves or removes the dot. O(1), which is what a drag needs.
    func applyCommunityPreviewHighlight(
        _ highlight: (listing: CommunityListing, coordinate: CLLocationCoordinate2D)?,
        on mapView: MKMapView
    ) {
        guard let highlight else {
            if let dot = communityPreviewHighlight {
                mapView.removeAnnotation(dot)
                communityPreviewHighlight = nil
            }
            return
        }
        if let dot = communityPreviewHighlight, dot.listingID == highlight.listing.id {
            if dot.coordinate.latitude != highlight.coordinate.latitude
                || dot.coordinate.longitude != highlight.coordinate.longitude {
                dot.coordinate = highlight.coordinate
            }
        } else {
            if let stale = communityPreviewHighlight {
                mapView.removeAnnotation(stale)
            }
            let dot = CommunityPreviewHighlightAnnotation(
                listing: highlight.listing,
                coordinate: highlight.coordinate
            )
            communityPreviewHighlight = dot
            mapView.addAnnotation(dot)
        }
        updateHighlightOpacity(on: mapView)
    }

    /// The dot's view, or `nil` for any other annotation — asked by `viewFor`
    /// before its last line, which draws whatever is left as the hike's own
    /// dot in the route tint.
    func communityPreviewHighlightView(
        for annotation: any MKAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView? {
        guard let dot = annotation as? CommunityPreviewHighlightAnnotation else { return nil }
        let view = highlightDotView(
            for: dot,
            tint: dot.tint,
            reuseIdentifier: CommunityPreviewHighlightAnnotation.reuseIdentifier,
            on: mapView
        )
        // In front of every pin. It starts at the trailhead, which is exactly
        // where a published hike's own marker stands — the route's first point
        // — and often a photograph's pin too, and at the default z-order MapKit
        // is free to draw the one thing the hiker is moving underneath them. A
        // pin's balloon is drawn above its point, so the dot covers no more of
        // one than its tip.
        view.zPriority = .max
        // For UI automation, which has nothing else to tell this dot from the
        // hike's by: both are an unlabelled circle.
        view.accessibilityIdentifier = "community-preview-highlight"
        return view
    }
}
