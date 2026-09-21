//
//  MapTrailPlaceAnnotations.swift
//  OpenHikes
//
//  The marked places on the map, and what their callouts say.
//
//  Two sources, one pin. While the maker is up they come from
//  ``TrailDraft/places`` and can be edited, moved and removed; on a hike that
//  has been saved they come from its ``TrailPoint`` rows through
//  ``TrailPlacePinController`` and can only be read. That is one annotation
//  class carrying an ``isEditable`` flag rather than two nearly identical
//  ones: the pin, the glyph, the callout's heading and the note inside it are
//  the same thing said about the same place, and the only difference is
//  whether there are buttons under it.
//
//  Editing a *saved* hike's places is deliberately not offered — the plan
//  issue puts editing an existing hike out of scope, and nothing here makes it
//  harder later: it is the flag, and the two buttons that are already written.
//
//  ## A place is a marker, a waypoint is a dot
//
//  Drawn apart on purpose, because they are different kinds of thing and are
//  on screen together. A waypoint is a numbered dot on the line — see
//  `MapTrailDraftOverlay.swift`, where the argument for the plain circle is
//  that what a hiker reads is where the *centre* of each point sits. A place
//  is not on the line at all, so it is a balloon whose tip points at the
//  ground it is about, in the symbol's own colour rather than the accent the
//  drawing wears.
//
//  Built out of `MKMarkerAnnotationView` for the reason
//  ``MapPhotoAnnotations`` gives: the balloon, the drop, the shadow, the
//  decluttering and the callout card are already drawn, and what is
//  app-specific is the glyph and a stack of buttons.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One ``TrailPlace``, in the shape MapKit wants it.
final class TrailPlaceAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailPlace"

    /// `var` for the drag, exactly as ``TrailDraftWaypointAnnotation``'s is:
    /// MapKit moves the view when this changes, so a pin under a finger
    /// follows it without being removed and added again per frame.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    private(set) var place: TrailPlace
    /// How far along the trail it sits, or `nil` where that cannot be said —
    /// no line yet, or too far off it to describe. See ``TrailPlaceAnchor``.
    let anchor: TrailPlaceAnchor?
    /// Whether this pin answers *Edit* and *Remove*. False on a saved hike.
    let isEditable: Bool

    @objc var title: String? { place.displayName }

    /// What it is and where, on one line — and the whole of what identifies an
    /// unnamed place, which is the normal case.
    @objc var subtitle: String? {
        let kind = place.symbol?.label
        let distance = anchor.map { measured in
            Measurement(value: measured.distanceAlongRouteMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
        // Only the parts there are. A named summit on a drawn line reads
        // "Summit · 2.3 km"; an unnamed one marked before anything was drawn
        // is titled "Place" and has nothing to add, so it says nothing rather
        // than drawing an empty second line.
        let parts = [kind, distance].compactMap(\.self)
        // A place whose name *is* its kind would otherwise say the same word
        // twice, once in each line of its own callout.
        let useful = place.name.isEmpty ? parts.filter { $0 != kind } : parts
        guard !useful.isEmpty else { return nil }
        return useful.joined(separator: " · ")
    }

    init(row: TrailPlaceRow, isEditable: Bool) {
        place = row.place
        coordinate = row.place.clCoordinate
        anchor = row.anchor
        self.isEditable = isEditable
    }

    /// Whether this pin would draw and read identically to `row`.
    ///
    /// What the rebuild compares, so a republish of the same places removes
    /// and re-adds no markers — the same guard ``MapView/Coordinator``'s photo
    /// pins make, for the same reason.
    func matches(_ row: TrailPlaceRow, isEditable: Bool) -> Bool {
        place.id == row.place.id
            && place.matches(row.place)
            && anchor == row.anchor
            && self.isEditable == isEditable
    }
}

#if os(iOS)
/// What sits inside a place's callout: its note, and the two verbs — either,
/// both or neither.
///
/// `nil` rather than an empty view when there is nothing to put in it, which
/// is the common case for a saved hike's unannotated place: MapKit draws the
/// callout around the heading alone, and an empty accessory would be a band of
/// blank card under it.
final class TrailPlaceCalloutView: UIStackView {
    static let editIdentifier = "trail-place-edit"
    static let removeIdentifier = "trail-place-remove"

    private static let width: CGFloat = 220
    private static let rowSpacing: CGFloat = 8

    private let noteLabel = UILabel()
    private let buttons = UIStackView()
    private var onEdit: (() -> Void)?
    private var onRemove: (() -> Void)?

    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Self.rowSpacing
        alignment = .fill
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        noteLabel.numberOfLines = 0
        noteLabel.font = .preferredFont(forTextStyle: .footnote)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = .secondaryLabel
        addArrangedSubview(noteLabel)

        buttons.axis = .horizontal
        buttons.spacing = Self.rowSpacing
        buttons.distribution = .fillEqually
        buttons.addArrangedSubview(
            button(
                title: String(localized: "Edit"),
                symbol: "square.and.pencil",
                identifier: Self.editIdentifier
            ) { [weak self] in self?.onEdit?() }
        )
        buttons.addArrangedSubview(
            button(
                title: String(localized: "Remove"),
                symbol: "trash",
                identifier: Self.removeIdentifier,
                tint: .systemRed
            ) { [weak self] in self?.onRemove?() }
        )
        addArrangedSubview(buttons)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("A trail place callout is created in code only")
    }

    /// Points the view at a place. Answers whether it has anything to draw, so
    /// the caller can leave the accessory off entirely.
    @discardableResult func show(
        _ place: TrailPlace,
        isEditable: Bool,
        onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> Bool {
        self.onEdit = onEdit
        self.onRemove = onRemove
        noteLabel.text = place.note
        noteLabel.isHidden = place.note.isEmpty
        buttons.isHidden = !isEditable
        return isEditable || !place.note.isEmpty
    }

    private func button(
        title: String,
        symbol: String,
        identifier: String,
        tint: UIColor? = nil,
        perform: @escaping () -> Void
    ) -> UIButton {
        var configuration: UIButton.Configuration = .bordered()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.titleLineBreakMode = .byWordWrapping
        if let tint { configuration.baseForegroundColor = tint }
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in perform() }, for: .touchUpInside)
        return button
    }
}
#endif

// MARK: - Drawing them

extension MapView.Coordinator {
    /// A balloon with the place's own glyph, and its note and verbs inside the
    /// callout.
    func trailPlaceAnnotationView(
        for annotation: TrailPlaceAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailPlaceAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        #if os(iOS)
        view.glyphImage = UIImage(systemName: annotation.place.systemImageName)
        // A place the hiker marked themselves, or one this trail carries.
        // Either way it is not scenery, so MapKit may not declutter it away.
        view.displayPriority = .required
        view.markerTintColor = UIColor(Self.trailPlaceTint(for: annotation.place))
        view.accessibilityIdentifier = annotation.isEditable
            ? "trail-draft-place"
            : "hike-place"
        attachTrailPlaceCallout(for: annotation, to: view, on: mapView)
        #endif
        // Last rather than beside the annotation, on the principle that the
        // last write wins: everything above it hands the view to MapKit — a
        // glyph, a tint, an accessory — and a recycled view is MapKit's own
        // object with its own history.
        view.canShowCallout = true
        return view
    }

    /// The marker's colour.
    ///
    /// One hue for every place but ``TrailPlaceSymbol/caution``, which is the
    /// only one of the eight that is a *warning* rather than a description —
    /// the same distinction ``TrailLegNotice`` draws between the orange glyph
    /// and the grey one, and the reason a leg with nothing mapped under it
    /// does not wear a triangle.
    ///
    /// Deliberately not the drawn line's accent and not the hike's own tint:
    /// a place is neither the trail nor part of it, and a pin in the line's
    /// colour would read as a point of it.
    private static func trailPlaceTint(for place: TrailPlace) -> Color {
        place.symbol == .caution ? .orange : .indigo
    }

    #if os(iOS)
    private func attachTrailPlaceCallout(
        for annotation: TrailPlaceAnnotation,
        to view: MKAnnotationView,
        on mapView: MKMapView
    ) {
        let callout = view.detailCalloutAccessoryView as? TrailPlaceCalloutView
            ?? TrailPlaceCalloutView()
        let hasContents = callout.show(
            annotation.place,
            isEditable: annotation.isEditable,
            onEdit: { [weak self, weak mapView] in
                // Closed before the sheet opens, for the reason a photo pin's
                // is: the callout belongs to a map the sheet is about to
                // cover, and one left standing is what the hiker comes back
                // to when the sheet goes.
                mapView?.deselectAnnotation(annotation, animated: true)
                self?.trailDraftController?.requestPlaceEditor(for: annotation.place.id)
            },
            onRemove: { [weak self, weak mapView] in
                mapView?.deselectAnnotation(annotation, animated: true)
                self?.trailDraftController?.removePlace(id: annotation.place.id)
            }
        )
        // Cleared rather than hidden when there is nothing in it: a hidden
        // accessory still occupies the callout, which is the band of empty
        // card this is avoiding.
        view.detailCalloutAccessoryView = hasContents ? callout : nil
    }
    #endif
}
