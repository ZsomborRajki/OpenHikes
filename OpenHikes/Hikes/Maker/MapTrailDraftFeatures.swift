//
//  MapTrailDraftFeatures.swift
//  OpenHikes
//
//  A tap on one of the map's own labels, while a trail is being drawn.
//
//  Apple Maps answers a tap on "Watzmann" with Watzmann, not with the address
//  of the slope under the label. The maker used to answer every tap the same
//  way — a coordinate, and a reverse-geocoded address a second later — so a
//  stop put on a summit, a hut or a trailhead car park read as a street name
//  or a municipality. MapKit can hand the label itself over: with
//  `selectableMapFeatures` set, a tap on one selects an `MKMapFeatureAnnotation`
//  carrying the name the label shows and the coordinate it stands for.
//
//  ## What that selection becomes
//
//  Not a selection. The feature is deselected at once and the maker's own
//  provisional pin is dropped on it instead, with the feature's name for a
//  heading — so the callout, its verbs and everything they do are the ones a
//  tap on open map already has, and a stop put down from it arrives named.
//  ``TrailStopNamer`` never asks about a point that has a name, so it costs no
//  lookup either. The name is the feature's own `title`: it is what the label
//  on screen said, it is there synchronously, and `MKMapItemRequest` would
//  spend a request to be told the same word.
//
//  ## Only while drawing, and only on Apple's own map
//
//  Outside the maker a tap on a label means nothing to this app, and MapKit's
//  own feature callout would be a second kind of callout on a map that
//  otherwise draws only its own. And over OpenStreetMap tiles Apple's labels
//  are not drawn at all — ``TileOverlay`` replaces the map's content — so
//  leaving the features selectable there would let a tap land on a label the
//  hiker cannot see. ``refreshTrailDraftFeatureSelection(on:)`` asks both
//  questions every time either answer can change.
//

import MapKit

extension MapView.Coordinator {
    /// The labels a tap may select while drawing: the places on the map and
    /// the ground itself — peaks, passes, lakes, valleys.
    private static let trailDraftSelectableFeatures: MKMapFeatureOptions = [.pointsOfInterest, .physicalFeatures]

    /// Makes the map's labels selectable exactly while the maker is up over
    /// Apple's own base map.
    ///
    /// Called from every pass that observes the draft and from every change of
    /// tile source, which between them are every moment either half of the
    /// question can change.
    func refreshTrailDraftFeatureSelection(on mapView: MKMapView) {
        let isDrawing = trailDraftController?.isEditing == true
        let wanted: MKMapFeatureOptions = isDrawing && tileOverlay == nil
            ? Self.trailDraftSelectableFeatures
            : []
        guard mapView.selectableMapFeatures != wanted else { return }
        mapView.selectableMapFeatures = wanted
    }

    /// Turns a selected label into the maker's provisional pin, named after it.
    ///
    /// - Returns: whether the selection was the maker's to answer, which is
    ///   what tells the delegate to stop there.
    func selectTrailDraftFeature(_ annotation: (any MKAnnotation)?, on mapView: MKMapView) -> Bool {
        guard let feature = annotation as? MKMapFeatureAnnotation else { return false }
        // Deselected whatever happens: a label selected with no maker to
        // answer it is the stale half of a race with the maker closing, and a
        // feature callout left open would be one this app never draws.
        mapView.deselectAnnotation(feature, animated: false)
        #if os(iOS)
        guard let controller = trailDraftController, controller.isEditing else { return true }
        let point = mapView.convert(feature.coordinate, toPointTo: mapView)
        showTrailDraftPin(
            at: feature.coordinate,
            legIndex: trailDraftLegIndex(at: point, in: mapView),
            named: BoundedText.boundedOrEmpty(feature.title ?? "", to: .title),
            offering: controller,
            in: mapView
        )
        #endif
        return true
    }
}
