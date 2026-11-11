//
//  MapCoordinator+FlattenButton.swift
//  OpenHikes
//
//  The 2D button: what lays a tilted map flat again, as the one in Maps does.
//
//  MapKit offers no such control for a UIKit map on iOS. `MKPitchControl` and
//  `showsPitchControl` are macOS and Mac Catalyst only, which is why only the
//  macOS branch of `MapView.addControls` turns the flag on, and SwiftUI's
//  `MapPitchToggle` drives a SwiftUI `Map` through its scope, never an
//  `MKMapView`. So this is a capsule of the app's own: the tracking button's
//  size and glass, standing directly on top of it, and riding the sheet with
//  it because it is constrained to it.
//
//  There only while the map is tilted, as in Maps: a map seen from straight
//  above has nothing for it to do. Tilted means the line the terrain rises
//  under the tiles at, ``SystemMapStyle/terrainPitch``, so the button is up
//  exactly while the relief is.
//
//  Shown as the camera moves rather than where it settles, so it arrives while
//  the hiker is still tilting: one comparison a frame, and a fade only when the
//  answer changes. A tap withdraws it at once rather than leaving it up through
//  the flattening it started, which is what `isFlattening` is for.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapView.Coordinator {
    /// Whether a camera at `pitch` is tilted far enough to offer the button.
    static func offersFlatten(atPitch pitch: CLLocationDegrees) -> Bool {
        pitch >= SystemMapStyle.terrainPitch
    }

    /// Every frame the camera moves, a tilt included. The only use of this
    /// callback, so it lives here rather than beside the settle in
    /// `MapCoordinator.swift`.
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        applyFlattenButtonVisibility(on: mapView, animated: true)
    }

    /// Where the camera came to rest, which ends a flattening: whatever the map
    /// settled at, the button now follows it again.
    func flattenButtonRegionDidSettle(on mapView: MKMapView) {
        isFlattening = false
        applyFlattenButtonVisibility(on: mapView, animated: true)
    }

    /// Shows the button while the map is tilted, and withdraws it once the map
    /// lies flat or a tap has started laying it flat.
    ///
    /// A comparison until the answer changes, because this runs on every frame
    /// of a pan.
    func applyFlattenButtonVisibility(on mapView: MKMapView, animated: Bool) {
        guard let flattenButton else { return }
        let visible = !isFlattening && Self.offersFlatten(atPitch: mapView.camera.pitch)
        guard visible != isFlattenButtonShown else { return }
        isFlattenButtonShown = visible
        flattenButton.fadeMapControl(
            visible: visible,
            restingAlpha: flattenButtonSheetAlpha,
            animated: animated
        ) { [weak self] in
            self?.isFlattenButtonShown == false
        }
    }

    /// Lays the map flat where it is, as the button in Maps does: the same
    /// centre, distance and heading, seen from straight above. The compass
    /// is what turns it north.
    func flatten(_ mapView: MKMapView) {
        let camera = mapView.camera
        isFlattening = true
        applyFlattenButtonVisibility(on: mapView, animated: true)
        mapView.setCamera(
            MKMapCamera(
                lookingAtCenter: camera.centerCoordinate,
                fromDistance: camera.centerCoordinateDistance,
                pitch: 0,
                heading: camera.heading
            ),
            animated: true
        )
    }

    /// Applies the sheet's fade, which the button shares with the tracking
    /// button it stands on.
    ///
    /// Remembered apart from whether the button is up, as the camera pill's
    /// is, so a tilt mid-drag fades it in to the sheet's opacity rather than
    /// to full.
    func applyFlattenButtonAlpha(_ alpha: CGFloat) {
        flattenButtonSheetAlpha = alpha
        guard let flattenButton, isFlattenButtonShown, flattenButton.alpha != alpha else { return }
        flattenButton.alpha = alpha
    }
}

extension MapView {
    /// The gap between the 2D button and the tracking button under it: two
    /// controls in one column, not one pill.
    private static let flattenButtonSpacing: CGFloat = 8
    private static let flattenTitlePointSize: CGFloat = 15

    /// The 2D button, in a glass capsule of its own over `tracking`.
    ///
    /// Words rather than a glyph, because Maps says *2D* and there is no
    /// symbol a hiker would read as it. In the label colour, as the tracking
    /// glyph is at rest: it is on glass, so the pair stays legible whatever
    /// the tiles underneath are doing.
    func addFlattenButton(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        above tracking: UIView
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "2D")
        configuration.baseForegroundColor = .label
        // The plain style's padding leaves a 44-point capsule too little width
        // for the word, which then wraps a character to a line.
        configuration.contentInsets = .zero
        configuration.titleLineBreakMode = .byClipping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: Self.flattenTitlePointSize, weight: .semibold)
            return outgoing
        }
        let button = UIButton(
            configuration: configuration,
            // The map holds the button through its subviews, and the
            // coordinator through its delegate. Weak, so neither loop closes.
            primaryAction: UIAction { [weak coordinator, weak mapView] _ in
                guard let coordinator, let mapView else { return }
                coordinator.flatten(mapView)
            }
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityHint = String(localized: "Shows the map flat, from straight above.")
        button.accessibilityIdentifier = "map-flatten-button"

        let glass = MapGlass.view(.capsule)
        glass.contentView.addSubview(button)
        // Starts withdrawn, as ``UIView/fadeMapControl(visible:restingAlpha:animated:isStillWithdrawn:)``
        // leaves a control: the first pass below decides, and a map is built
        // lying flat.
        glass.isHidden = true
        glass.alpha = 0
        glass.isUserInteractionEnabled = false
        mapView.addSubview(glass)

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: MapGlassPill.controlSize),
            glass.heightAnchor.constraint(equalToConstant: MapGlassPill.controlSize),
            glass.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: tracking.topAnchor, constant: -Self.flattenButtonSpacing),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])

        coordinator.flattenButton = glass
        coordinator.applyFlattenButtonVisibility(on: mapView, animated: false)
    }
}
#endif
