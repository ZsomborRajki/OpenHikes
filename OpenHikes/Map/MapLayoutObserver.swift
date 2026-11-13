//
//  MapLayoutObserver.swift
//  OpenHikes
//
//  How the row along the map's bottom hears that the map changed size.
//
//  That row — the "my location" button, the credit line and the pill above it
//  — is placed by a constant measured from the map's own height: see
//  `MapCoordinator+TrackingButton.swift`. So it is measured again whenever the
//  height moves, and SwiftUI was what said that it had. On a phone a turn
//  swaps the sheet for the side panel, which is an input of ``MapView``, so
//  `update(_:_:)` ran and measured on its way through.
//
//  An iPad keeps the panel either way up. Turning one changes no input,
//  `MapView.==` holds, and `update` never runs: the row stayed where the other
//  way up had put it, which after a turn to landscape is 300 points under the
//  bottom edge, the record and trail buttons with it. A window resized on
//  iPadOS 26 is the same case at every size in between.
//
//  So the map says so itself. `MKMapView` is not meant to be subclassed, and
//  its delegate hears about the region and never about the bounds; a subview
//  pinned to the map's height is laid out exactly when that height changes.
//

#if os(iOS)
import MapKit
import UIKit

/// Draws nothing, takes no touch, and reports each time the map it is pinned
/// to changes height or safe area.
final class MapLayoutObserver: UIView {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapLayoutObserver is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onChange()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onChange()
    }
}

extension MapView {
    /// Has the map's bottom row follow the map's own size — see the file
    /// header for why SwiftUI cannot be what tells it.
    ///
    /// No width, so there is nothing of it to draw or to touch, and the map's
    /// full height, so its bounds change with the map's and at no other time.
    func addLayoutObserver(to mapView: MKMapView, _ coordinator: Coordinator) {
        // The map holds the observer through its subviews, and the coordinator
        // through its delegate. Weak, so neither loop closes.
        let observer = MapLayoutObserver { [weak coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.applySheetTopIfGeometryChanged(on: mapView)
        }
        observer.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(observer)
        NSLayoutConstraint.activate([
            observer.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            observer.topAnchor.constraint(equalTo: mapView.topAnchor),
            observer.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),
            observer.widthAnchor.constraint(equalToConstant: 0),
        ])
    }
}
#endif
