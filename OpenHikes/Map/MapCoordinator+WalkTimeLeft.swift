//
//  MapCoordinator+WalkTimeLeft.swift
//  OpenHikes
//
//  How long the walk under way has left, standing on the line it has left to
//  walk.
//
//  The figure is the walk's own — ``TrailWalkSession/secondsLeft(at:)``, the
//  one the hike's screen, the Live Activity and the after-dark warning read —
//  at the walk's own pace, over the way to the end it is going for, timed
//  for what the trail was drawn for. It stands halfway along that way (see
//  ``WalkTimeLeft``), in the capsule the trail maker puts a drawn route's
//  time in, filled as the maker fills the route drawn.
//
//  **Only over the walked hike's own line.** The walk outlives its screen,
//  and browsing another trail draws that trail instead; a time left on a line
//  the map is not drawing would be a bubble in a field. So it is drawn while
//  the map's route is the walked hike and taken away when it is not.
//
//  **At the rate of the matches.** Observed on the walk's per-fix figure
//  (``TrailWalkSession/metersLeft``) and its coarse ones — which hike, which
//  phase — the way the progress row under the chart is, and moved rather
//  than replaced, so a fix slides the bubble along the line instead of
//  dropping a new one. Between fixes the clock runs on and the figure stands,
//  as the row's does.
//
//  **Nothing while backgrounded.** A walk is matched in a pocket all
//  afternoon, and a bubble moved for nobody is the cost the recording trace
//  refuses too — see ``MapView/Coordinator/isForeground``. The change is
//  noted and drawn once, on return.
//
//  **A tap on it is a tap on the line under it.** The bubble is a view, so
//  it claims the touch from the route's own recognizer — see
//  ``MapView/Coordinator/isTapClaimed(at:in:)`` — and stands on the one line
//  that always has it. Left to MapKit, that stretch of line would open
//  nothing and the bubble would stay selected, deaf to a second tap. So it
//  opens the walked hike, as a tap beside it does.
//

import MapKit
import OpenHikesData
import OpenHikesShared
#if canImport(UIKit)
import UIKit
#endif

/// What the map has drawn of the walk's time left — see
/// `MapCoordinator+WalkTimeLeft.swift`.
struct WalkTimeLeftMapState {
    weak var walk: TrailWalkSession?
    weak var mapView: MKMapView?
    var annotation: WalkTimeLeftAnnotation?
    /// Whether the walk moved while the app was in the background, and the
    /// bubble is owed a pass on return.
    var isPending = false
}

/// The time left on the walk under way, halfway along the way ahead.
final class WalkTimeLeftAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "walkTimeLeft"

    /// Moved in place as the walk goes on. `dynamic`, so MapKit hears the
    /// move through key-value observing and takes the view with it.
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var seconds: TimeInterval

    @objc var title: String? { String(localized: "\(HikeFormat.travelTime(seconds)) left") }
    @objc let subtitle: String? = nil

    init(_ mark: WalkTimeLeftMark) {
        coordinate = mark.coordinate
        seconds = mark.seconds
    }

    var spokenDescription: String {
        String(localized: "\(HikeFormat.spokenTravelTime(seconds)) left")
    }
}

#if os(iOS)
/// The bubble: the time left in the accent colour — see
/// ``TravelTimeBubbleView``.
final class WalkTimeLeftView: TravelTimeBubbleView {
    func show(_ annotation: WalkTimeLeftAnnotation) {
        self.annotation = annotation
        // The asset rather than `Color.accentColor`, which bridges to the
        // tint and is greyed behind a sheet — see
        // ``MapView/Coordinator/trailDraftTint(on:)``. A view's background
        // resolves against the map's own appearance by itself.
        showTime(annotation.title, fill: MapView.Coordinator.accentAsset)
        // Never gives way, as the maker's route time does not: MapKit settles
        // a collision by hiding the lower priority, and a place's pin beside
        // it would take the walk's one figure off the map.
        displayPriority = .required
        accessibilityLabel = annotation.spokenDescription
        // It opens the walked hike — see the file header.
        accessibilityTraits = .button
        accessibilityIdentifier = "walk-time-left"
    }
}
#endif

extension MapView.Coordinator {
    /// Draws the walk's time left, then re-registers for the next change —
    /// see the file header.
    func observeWalkTimeLeft(_ walk: TrailWalkSession, on mapView: MKMapView) {
        walkTimeLeft.walk = walk
        walkTimeLeft.mapView = mapView
        applyWalkTimeLeft(on: mapView)
        reobserving(self, mapView, walk) {
            _ = walk.walkedHikeID
            _ = walk.phase
            _ = walk.metersLeft
        } onChange: { coordinator, map, model in
            coordinator.observeWalkTimeLeft(model, on: map)
        }
    }

    /// Puts the bubble where the walk now says, moves it there, or takes it
    /// away — or, in the background, notes that it is owed a pass.
    ///
    /// Asked by the observation above, and by the route changing under it:
    /// the bubble belongs to the walked hike's line, so selecting another
    /// hike takes it away and selecting the walked one brings it back.
    func applyWalkTimeLeft(on mapView: MKMapView) {
        guard isForeground else {
            walkTimeLeft.isPending = true
            return
        }
        walkTimeLeft.isPending = false
        let mark = walkTimeLeft.walk?.timeLeftMark().flatMap { $0.hikeID == routeID ? $0 : nil }
        guard let mark else {
            if let drawn = walkTimeLeft.annotation {
                mapView.removeAnnotation(drawn)
                walkTimeLeft.annotation = nil
            }
            return
        }
        guard let drawn = walkTimeLeft.annotation else {
            let annotation = WalkTimeLeftAnnotation(mark)
            walkTimeLeft.annotation = annotation
            mapView.addAnnotation(annotation)
            return
        }
        drawn.coordinate = mark.coordinate
        drawn.seconds = mark.seconds
        #if os(iOS)
        // A view MapKit has not made yet takes the figure when it is asked for.
        (mapView.view(for: drawn) as? WalkTimeLeftView)?.show(drawn)
        #endif
    }

    /// A tap on the bubble, which opens the walked hike as a tap on its line
    /// does — see the file header. Answers whether the tap was on it.
    func selectWalkTimeLeft(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard let timeLeft = view.annotation as? WalkTimeLeftAnnotation else { return false }
        // Let go of, so a second tap is heard after Back.
        mapView.deselectAnnotation(timeLeft, animated: false)
        HapticMoment.targetHit.play()
        drawnRouteTap?.open()
        return true
    }

    /// The pass the bubble is owed for a walk that moved in the background —
    /// see the file header.
    func applyPendingWalkTimeLeft() {
        guard walkTimeLeft.isPending, let mapView = walkTimeLeft.mapView else { return }
        applyWalkTimeLeft(on: mapView)
    }

    /// The bubble's view, or `nil` for an annotation that is not the walk's.
    func walkTimeLeftView(for annotation: any MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        guard let timeLeft = annotation as? WalkTimeLeftAnnotation else { return nil }
        #if os(iOS)
        let view = mapView.reusableView(
            WalkTimeLeftView.self,
            for: timeLeft,
            reuseIdentifier: WalkTimeLeftAnnotation.reuseIdentifier
        )
        view.show(timeLeft)
        return view
        #else
        return mapView.reusableView(
            MKAnnotationView.self,
            for: timeLeft,
            reuseIdentifier: WalkTimeLeftAnnotation.reuseIdentifier
        )
        #endif
    }
}
