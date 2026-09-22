//
//  MapTrailDraftRouteChoices.swift
//  OpenHikes
//
//  The other routes a leg could take, and how long each one takes — drawn on
//  the map the way Apple Maps draws them.
//
//  A leg's router can answer with more than one way between its two stops —
//  see ``TrailLeg/alternatives``. The one drawn is the accent line; the others
//  are wider, paler lines under it, and a tap on one draws that instead. Every
//  leg carries a bubble with its time, and every alternative one with its own,
//  so the choice is made on what it costs rather than on how it looks.
//
//  **Hidden while a stop is dragged.** The two legs either side of a moving
//  point are rubber bands until it lands; their alternatives and times are
//  about the shape it had, and would be wrong for as long as the finger is
//  down. They come back with the rebuild the drop causes, or as they were if
//  the point went nowhere.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Which leg an alternative line belongs to, and which of its alternatives it
/// is. Kept beside the overlay, keyed by identity, for the reason a leg's style
/// is: the draft's lines stay plain `MKPolyline`s.
nonisolated struct TrailDraftRouteChoice: Equatable, Sendable {
    let legIndex: Int
    let alternativeIndex: Int
}

/// What the map has drawn of the route choices, so they can be taken down
/// again and a tap can find the one under it.
struct TrailDraftRouteChoiceLayer {
    var lines: [MKPolyline] = []
    var choices: [ObjectIdentifier: TrailDraftRouteChoice] = [:]
    var times: [TrailDraftTravelTimeAnnotation] = []
}

/// How long a leg, or one of its alternatives, takes — the bubble on the line.
final class TrailDraftTravelTimeAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftTravelTime"

    @objc dynamic let coordinate: CLLocationCoordinate2D
    let legIndex: Int
    /// `nil` for the route drawn; an index into the leg's alternatives for one
    /// on offer, which a tap chooses.
    let alternativeIndex: Int?
    let travelTime: TimeInterval

    @objc var title: String? { HikeFormat.travelTime(travelTime) }
    @objc let subtitle: String? = nil

    init(
        coordinate: CLLocationCoordinate2D,
        legIndex: Int,
        alternativeIndex: Int?,
        travelTime: TimeInterval
    ) {
        self.coordinate = coordinate
        self.legIndex = legIndex
        self.alternativeIndex = alternativeIndex
        self.travelTime = travelTime
    }

    var spokenDescription: String {
        let time = HikeFormat.spokenTravelTime(travelTime)
        return alternativeIndex == nil
            ? time
            : String(localized: "Alternative route, \(time)")
    }
}

#if os(iOS)
/// The bubble: the time in a capsule, filled for the route drawn and plain for
/// one on offer.
final class TrailDraftTravelTimeView: MKAnnotationView {
    private static let padding = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    private static let shadowOpacity: Float = 0.2

    private let label = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        collisionMode = .rectangle
        label.font = .preferredFont(forTextStyle: .caption1).bold
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        addSubview(label)
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A travel time bubble is created in code only")
    }

    func show(_ annotation: TrailDraftTravelTimeAnnotation) {
        self.annotation = annotation
        let isChosen = annotation.alternativeIndex == nil
        label.text = annotation.title
        label.textColor = isChosen ? .white : .label
        backgroundColor = isChosen ? UIColor(Color.accentColor) : .systemBackground
        displayPriority = isChosen ? .defaultHigh : .defaultLow
        accessibilityLabel = annotation.spokenDescription
        accessibilityTraits = isChosen ? .staticText : .button
        accessibilityIdentifier = isChosen ? "trail-draft-leg-time" : "trail-draft-alternative-time"
        let size = label.intrinsicContentSize
        bounds = CGRect(
            x: 0,
            y: 0,
            width: size.width + Self.padding.left + Self.padding.right,
            height: size.height + Self.padding.top + Self.padding.bottom
        )
        label.frame = bounds.inset(by: Self.padding)
        layer.cornerRadius = bounds.height / 2
    }
}

private extension UIFont {
    var bold: UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
#endif

extension MapView.Coordinator {
    private static let alternativeLineWidth: CGFloat = 6
    private static let alternativeLineAlpha: CGFloat = 0.4

    /// Draws every leg's alternatives and every time bubble.
    ///
    /// The alternatives go **under** the drawn line, which is already on the
    /// map and stays there across a commit — see `MapTrailDraftOverlay.swift`
    /// — so they are inserted below the lowest of its legs rather than added
    /// on top of them.
    func addTrailDraftRouteChoices(for legs: [TrailLeg], of draft: TrailDraft, to mapView: MKMapView) {
        removeTrailDraftRouteChoices(from: mapView)
        var layer = TrailDraftRouteChoiceLayer()
        for (legIndex, leg) in legs.enumerated() where !leg.snap.isRouting {
            layer.times.append(TrailDraftTravelTimeAnnotation(
                coordinate: Self.midpoint(of: leg.coordinates),
                legIndex: legIndex,
                alternativeIndex: nil,
                travelTime: draft.travelTime(of: leg.path)
            ))
            for (index, path) in leg.alternatives.enumerated() {
                let coordinates = path.coordinates.map { point in
                    CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                }
                let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                layer.lines.append(line)
                layer.choices[ObjectIdentifier(line)] = TrailDraftRouteChoice(
                    legIndex: legIndex,
                    alternativeIndex: index
                )
                layer.times.append(TrailDraftTravelTimeAnnotation(
                    coordinate: Self.midpoint(of: path.coordinates),
                    legIndex: legIndex,
                    alternativeIndex: index,
                    travelTime: draft.travelTime(of: path)
                ))
            }
        }
        trailDraftRouteChoices = layer
        // `overlays(in:)` lists a level bottom first, so the first of the
        // draft's own lines in it is the one everything goes beneath.
        let lowestLeg = mapView.overlays(in: .aboveLabels).first { overlay in
            (overlay as? MKPolyline).map { trailDraftLegStyles[ObjectIdentifier($0)] != nil } == true
        }
        if let lowestLeg {
            for line in layer.lines { mapView.insertOverlay(line, below: lowestLeg) }
        } else {
            mapView.addOverlays(layer.lines, level: .aboveLabels)
        }
        mapView.addAnnotations(layer.times)
    }

    func removeTrailDraftRouteChoices(from mapView: MKMapView) {
        let drawn = trailDraftRouteChoices
        if !drawn.lines.isEmpty { mapView.removeOverlays(drawn.lines) }
        if !drawn.times.isEmpty { mapView.removeAnnotations(drawn.times) }
        trailDraftRouteChoices = TrailDraftRouteChoiceLayer()
    }

    /// The alternative under a tap, unless the drawn route is at least as
    /// close — a tap on the line itself drops a pin on it.
    func trailDraftAlternative(at point: CGPoint, in mapView: MKMapView) -> TrailDraftRouteChoice? {
        let lines = trailDraftRouteChoices.lines
        guard !lines.isEmpty else { return nil }
        let tolerance = Self.lineTapTolerancePoints
        let projected = lines.map { Self.points(of: $0, in: mapView) }
        guard let hit = RouteHitTest.nearest(to: point, among: projected, tolerance: tolerance),
              let distance = RouteHitTest.distance(from: point, to: projected[hit]) else { return nil }
        if let leg = trailDraftLegIndex(at: point, in: mapView),
           trailDraftOverlays.indices.contains(leg),
           let legDistance = RouteHitTest.distance(
               from: point,
               to: Self.points(of: trailDraftOverlays[leg], in: mapView)
           ),
           legDistance <= distance {
            return nil
        }
        return trailDraftRouteChoices.choices[ObjectIdentifier(lines[hit])]
    }

    func trailDraftAlternativeRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        guard trailDraftRouteChoices.choices[ObjectIdentifier(polyline)] != nil else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor(Color.accentColor).withAlphaComponent(Self.alternativeLineAlpha)
        #else
        renderer.strokeColor = UIColor(Color.accentColor).withAlphaComponent(Self.alternativeLineAlpha)
        #endif
        renderer.lineWidth = Self.alternativeLineWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    func trailDraftTravelTimeView(
        for annotation: TrailDraftTravelTimeAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        #if os(iOS)
        let identifier = TrailDraftTravelTimeAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? TrailDraftTravelTimeView
            ?? TrailDraftTravelTimeView(annotation: annotation, reuseIdentifier: identifier)
        view.show(annotation)
        return view
        #else
        MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        #endif
    }

    /// Halfway along a shape by distance, which is where a bubble sits: on the
    /// part of an alternative that differs, rather than at an end it shares.
    static func midpoint(of shape: [RouteCoordinate]) -> CLLocationCoordinate2D {
        let points = shape.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let first = points.first else { return kCLLocationCoordinate2DInvalid }
        let lengths = zip(points, points.dropFirst()).map { RouteGeometry.distanceMeters(from: $0, to: $1) }
        var remaining = lengths.reduce(0, +) / 2
        for (index, length) in lengths.enumerated() {
            guard remaining > length else {
                return RouteGeometry.interpolate(
                    from: points[index],
                    to: points[index + 1],
                    fraction: length > 0 ? remaining / length : 0
                )
            }
            remaining -= length
        }
        return points.last ?? first
    }
}
