//
//  MapTrailDraftRoutingBadge.swift
//  OpenHikes
//
//  A spinner on a leg OpenStreetMap is still being asked about.
//
//  The short dash alone did not say it. A leg waiting for an answer is drawn as
//  a straight dotted line, and a straight dotted line that does not move reads
//  as a line drawn in a different style rather than as one about to change —
//  while an Overpass answer can take several seconds to come back. *Finding a
//  path…* was said, but only as the caption under the list in the sheet, which
//  at the compact and medium detents is below the fold or not drawn at all.
//
//  So the leg says it itself, in the place its time will be: a bubble at its
//  middle, the shape the time bubbles are drawn in, with a system spinner and
//  the same sentence the sheet's caption uses. It is one of the route-choice
//  layer's annotations — see `MapTrailDraftRouteChoices.swift` — so it comes
//  and goes on that layer's schedule: drawn when a leg starts routing, taken
//  down by the rebuild its answer causes, and hidden while a stop is dragged,
//  when nothing has been asked yet.
//
//  **The spinner costs no map redraw.** `UIActivityIndicatorView` turns in Core
//  Animation, on the annotation's own layer, so nothing asks MapKit to draw a
//  line again while it spins; a dash phase stepped on a timer would have
//  redrawn the leg's renderer at every step.
//

import MapKit
import OpenHikesData
#if canImport(UIKit)
import UIKit
#endif

/// One leg still being routed, at its middle.
final class TrailDraftRoutingAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftRouting"

    @objc dynamic let coordinate: CLLocationCoordinate2D

    /// What the sheet's caption says about a leg in this state, so the map and
    /// the sheet say the same thing — see ``TrailLegSnap/notice``.
    @objc var title: String? { TrailLegSnap.routing.notice?.text }
    @objc let subtitle: String? = nil

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

#if os(iOS)
/// The bubble: a spinner and the sentence, in the capsule an alternative's time
/// is drawn in, because it is the slot the leg's time will land in.
final class TrailDraftRoutingView: MKAnnotationView {
    private static let padding = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
    private static let spacing: CGFloat = 4
    private static let shadowOpacity: Float = 0.2

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let stack: UIStackView

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        stack = UIStackView(arrangedSubviews: [spinner, label])
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .rectangle
        // Below the route's own time and the stops: on a crowded line it is
        // the one MapKit hides, and the dash still says what it says.
        displayPriority = .defaultLow
        backgroundColor = .systemBackground
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Self.spacing
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        addSubview(stack)
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        accessibilityIdentifier = "trail-draft-routing"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A routing bubble is created in code only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimating()
    }

    func show(_ annotation: TrailDraftRoutingAnnotation) {
        self.annotation = annotation
        label.text = annotation.title
        accessibilityLabel = annotation.title
        spinner.startAnimating()
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bounds = CGRect(
            x: 0,
            y: 0,
            width: size.width + Self.padding.left + Self.padding.right,
            height: size.height + Self.padding.top + Self.padding.bottom
        )
        stack.frame = bounds.inset(by: Self.padding)
        layer.cornerRadius = bounds.height / 2
    }
}
#endif

extension MapView.Coordinator {
    /// One bubble for every leg still being routed, halfway along the line it
    /// is drawn as while it waits.
    static func trailDraftRoutingBadges(for legs: [TrailLeg]) -> [TrailDraftRoutingAnnotation] {
        legs.filter(\.snap.isRouting).map { leg in
            // The same fallback ``trailDraftLine(for:)`` draws a collapsed
            // shape with: the straight line between the leg's ends.
            let shape = leg.coordinates.count >= 2 ? leg.coordinates : [leg.ends.start, leg.ends.end]
            return TrailDraftRoutingAnnotation(coordinate: midpoint(of: shape))
        }
    }

    func trailDraftRoutingView(
        for annotation: TrailDraftRoutingAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        #if os(iOS)
        let view = mapView.reusableView(
            TrailDraftRoutingView.self,
            for: annotation,
            reuseIdentifier: TrailDraftRoutingAnnotation.reuseIdentifier
        )
        view.show(annotation)
        return view
        #else
        MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        #endif
    }
}
