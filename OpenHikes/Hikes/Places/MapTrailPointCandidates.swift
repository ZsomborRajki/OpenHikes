//
//  MapTrailPointCandidates.swift
//  OpenHikes
//
//  What OpenStreetMap offered, on the map, in a style that says it is only an
//  offer.
//
//  ## Drawn apart from the places the hiker has marked, deliberately
//
//  A marked place is indigo, is drawn at ``MKFeatureDisplayPriority/required``
//  and carries *Edit* and *Remove*. A candidate is grey, may be decluttered
//  away, and carries one verb. That is the whole difference and it is the
//  whole point: nothing on this layer is in the draft, on the disk or in the
//  saved hike, and a pin that looked like the ones that are would be this app
//  claiming the hiker had marked forty things they have not looked at yet.
//
//  **Every one of those differences is something to look at**, which is why
//  the pin says the same thing in words — see ``TrailPointCandidateAnnotation/spokenDescription``.
//  A candidate and a marked place carry the same title and the same subtitle,
//  so without it a hiker swiping through the map's elements hears forty pins
//  and cannot tell which three are theirs.
//
//  Decluttering is *wanted* here rather than tolerated. There are up to forty
//  of these — see ``TrailPointQuery/maximumResults`` — and MapKit thinning
//  them as the hiker zooms out is exactly the behaviour a provisional layer
//  should have. A marked place may never be thinned, because it is a fact
//  about the trail.
//
//  ## A tap on one claims its own tap, for free
//
//  ``MapView/Coordinator/isTapClaimed(at:in:)`` gives a tap to any
//  `MKAnnotationView`, so a candidate answers a touch without anything being
//  added anywhere and without the canvas's own tap ever seeing it. MapKit then
//  opens the callout itself, which is why none of the reopening dance
//  ``TrailDraftDroppedPin/mayReopen`` needs applies here: that one is about a
//  callout *this app* opens from its own recognizer, racing MapKit's handling
//  of the same tap. This is MapKit's own selection, on MapKit's own schedule.
//
//  ## Marking one does not open the editor, and the other three flows do
//
//  A place marked from the map centre, from a tapped spot or from the hiker's
//  own position arrives with no name and no symbol, so naming it *is* the rest
//  of the gesture. A candidate arrives with both — it is a waterfall, and it
//  is called Waterfall — so the editor would be a sheet over the map asking a
//  question that is already answered. Adopting several in a row is then four
//  taps rather than twelve, which is what a hiker marking the springs along a
//  climb is actually doing. Nothing is lost by it either: the provisional pin
//  is replaced by the marked place's own, and *that* one's callout offers
//  *Edit* to anybody who wants to say more about it.
//

import MapKit
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One place OpenStreetMap offered, in the shape MapKit wants it.
///
/// Carries the whole ``TrailPlaceRow`` rather than a coordinate, because what
/// identifies most of these is not a name: an unnamed waterfall is "Waterfall
/// · 2.3 km" and both halves of that come from the row.
final class TrailPointCandidateAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailPointCandidate"

    let row: TrailPlaceRow

    @objc dynamic var coordinate: CLLocationCoordinate2D { row.place.clCoordinate }

    /// What it is called, which for four fifths of these is what it *is* —
    /// see ``TrailPlace/displayName``.
    @objc var title: String? { row.place.displayName }

    /// How far along the drawing it sits, or nothing at all where that cannot
    /// be said: no line yet, or too far off it to be described by it. A name
    /// is not repeated here, because for a named summit the title is the name
    /// and the kind is worth saying, while for an unnamed one the title is
    /// already the kind.
    @objc var subtitle: String? {
        let kind = row.place.name.isEmpty ? nil : row.place.symbol?.label
        let distance = row.anchor.map { anchor in
            Measurement(value: anchor.distanceAlongRouteMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
        let parts = [kind, distance].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// What a screen reader is told, which has to say more than the callout
    /// draws.
    ///
    /// Colour, thinning and which buttons the callout carries are the whole of
    /// what separates one of these from a place the hiker marked, and not one
    /// of them is audible. So the pin says the part that matters: nothing has
    /// been added to the trail yet. It is set on the *view* rather than folded
    /// into ``subtitle``, because the subtitle is a line of text under a pin
    /// on a map and this is a sentence.
    var spokenDescription: String {
        let drawn = [title, subtitle].compactMap(\.self).joined(separator: ", ")
        return String(localized: "\(drawn). Found in OpenStreetMap, not on your trail yet.")
    }

    init(row: TrailPlaceRow) {
        self.row = row
    }
}

#if os(iOS)
/// The one verb a candidate's callout carries.
///
/// Its own small view for the reason every other callout accessory in this
/// feature is one: a `Menu`'s contents do not survive into the automation and
/// a view this code owns does. See ``TrailDraftPinAction``.
final class TrailPointCandidateCalloutView: UIStackView {
    static let markIdentifier = "trail-point-mark"

    private var handler: (() -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        translatesAutoresizingMaskIntoConstraints = false
        var configuration: UIButton.Configuration = .borderedProminent()
        configuration.title = String(localized: "Mark This Place")
        configuration.image = UIImage(systemName: "mappin.and.ellipse")
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.titleLineBreakMode = .byWordWrapping
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = Self.markIdentifier
        button.addAction(
            UIAction { [weak self] _ in self?.handler?() },
            for: .touchUpInside
        )
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("A trail point callout is created in code only")
    }

    func onMark(_ perform: @escaping () -> Void) {
        handler = perform
    }
}
#endif

// MARK: - Drawing them

extension MapView.Coordinator {
    /// A grey balloon with the place's own glyph, and one button inside its
    /// callout.
    func trailPointCandidateView(
        for annotation: TrailPointCandidateAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailPointCandidateAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        #if os(iOS)
        view.glyphImage = UIImage(systemName: annotation.row.place.systemImageName)
        // Grey, and thinned when the map is busy — see this file's header for
        // why both of those are the offer saying it is only an offer.
        view.markerTintColor = .systemGray
        view.displayPriority = .defaultLow
        view.accessibilityIdentifier = "trail-point-candidate"
        // Overrides the title-and-subtitle MapKit would otherwise read, which
        // is word for word what a place the hiker marked reads — see
        // ``TrailPointCandidateAnnotation/spokenDescription``.
        view.accessibilityLabel = annotation.spokenDescription
        attachTrailPointCandidateCallout(for: annotation, to: view, on: mapView)
        #endif
        // Last rather than beside the annotation, on the principle the marked
        // places' own view follows: everything above hands the view to MapKit,
        // and a recycled view is MapKit's own object with its own history.
        view.canShowCallout = true
        return view
    }

    /// Replaces the candidates on the map with `rows`.
    ///
    /// Wholesale rather than diffed, like every other annotation layer in this
    /// feature: this runs when a search lands, when one is taken and when the
    /// drawing changes enough to move the distances — never at drag or fix
    /// frequency. The guard in front of it is what keeps a re-rank that
    /// changed nothing from removing and re-adding forty pins.
    func applyTrailPointCandidates(_ rows: [TrailPlaceRow], on mapView: MKMapView) {
        let drawn = trailPointCandidateAnnotations
        guard drawn.count != rows.count
            || !zip(drawn, rows).allSatisfy({ $0.row == $1 })
        else { return }

        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
            trailPointCandidateAnnotations = []
            // One of them may have been the open callout — the tidy-up
            // ``applyPhotoPins(_:on:)`` documents, for the same reason.
            refreshOpenCallout(on: mapView)
        }
        guard !rows.isEmpty else { return }
        let annotations = rows.map(TrailPointCandidateAnnotation.init(row:))
        trailPointCandidateAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// Marks one of the offered places, and takes its provisional pin away.
    ///
    /// Split from the button's own closure for the reason
    /// ``applyTrailDraftPin(_:at:legIndex:in:)`` was split from its callout: a
    /// `UIButton` inside a callout inside an `MKAnnotationView` is not
    /// something a suite can press, and this is the half worth asserting on.
    ///
    /// The pin goes because the finder drops the candidate — see
    /// ``TrailDraftController/adopt(_:)`` — and a marked place's own pin
    /// arrives in its place. Deselecting first is what keeps the callout from
    /// being left standing over a pin that has gone.
    func markTrailPointCandidate(
        _ annotation: TrailPointCandidateAnnotation,
        on mapView: MKMapView
    ) {
        mapView.deselectAnnotation(annotation, animated: true)
        guard trailDraftController?.adopt(annotation.row.place) != nil else { return }
        HapticMoment.targetHit.play()
    }

    #if os(iOS)
    private func attachTrailPointCandidateCallout(
        for annotation: TrailPointCandidateAnnotation,
        to view: MKAnnotationView,
        on mapView: MKMapView
    ) {
        let callout = view.detailCalloutAccessoryView as? TrailPointCandidateCalloutView
            ?? TrailPointCandidateCalloutView()
        view.detailCalloutAccessoryView = callout
        callout.onMark { [weak self, weak mapView] in
            guard let self, let mapView else { return }
            markTrailPointCandidate(annotation, on: mapView)
        }
    }
    #endif
}
