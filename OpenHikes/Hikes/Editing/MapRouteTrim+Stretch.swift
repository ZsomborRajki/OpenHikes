//
//  MapRouteTrim+Stretch.swift
//  OpenHikes
//
//  *Edit Route*'s half of the map beyond the two cuts: the stretch the
//  handles pick out, and a line held and pulled through another spot. See
//  `RouteTrimSession+Steps.swift`, whose steps this asks for.
//
//  ## A stretch picked out
//
//  While the handles pick a stretch out they cut nothing, so the two covers
//  that gray a cut-off end stroke nothing, and the whole line goes on the
//  map once more, dashed in orange as a section to check is, stroked between
//  the handles. A handle moving is again two numbers written to one renderer.
//
//  ## A pull
//
//  A finger held on the line takes hold of it there. The stretch that would
//  be redrawn — out to the nearest junction each side, or as far as the
//  map's zoom gives — is covered in gray, and a dashed band runs from one
//  end of it through the finger to the other: where the line would go, as
//  near as anything can say before a path has been asked for. Lifting the
//  finger asks for the path. A finger lifted where it came down asks for
//  nothing.
//
//  Its own recognizer rather than the handles', which takes hold after a
//  tenth of a second: a line runs across the whole map, and a pan that
//  happened to begin on it has to stay a pan.
//

import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RouteStretchMapState {
    /// The whole line once more, stroked between the handles while they pick
    /// a stretch out.
    var picked: MKPolyline?
    weak var pickedRenderer: MKPolylineRenderer?

    #if canImport(UIKit)
    var pullRecognizer: UILongPressGestureRecognizer?
    #endif
    /// The stretch a pull under way would redraw, in metres along the line.
    var pulled: ClosedRange<Double>?
    /// What that stretch was measured on, which the step must be made on.
    var pulledOn: RouteTrimSession.StepGround?
    /// Where the finger came down, so one lifted there asks for nothing.
    var pullOrigin: CGPoint = .zero
    /// The stretch as it is, grayed, and the band through the finger.
    var pullCover: MKPolyline?
    var pullBand: MKPolyline?
    var pausedScrolling = false
}

extension MapView.Coordinator {
    /// How long a finger rests on the line before it takes hold of it.
    private static let pullPressDuration: TimeInterval = 0.35
    /// How far either side of the finger a pull takes where no junction is
    /// known near, in points on the map: a zoomed-in pull moves a short
    /// stretch, and a zoomed-out one a long one.
    private static let pullReachPoints: CGFloat = 70
    private static let pullBandWidth: CGFloat = 5

    // MARK: A stretch picked out

    /// The overlay that picks the stretch out, for a session whose handles
    /// are picking one.
    func routeStretchOverlay(of line: RouteTrimLine, in session: RouteTrimSession) -> MKPolyline? {
        guard session.isSelectingStretch else { return nil }
        let coordinates = line.profile.coordinates
        let picked = MKPolyline(coordinates: coordinates, count: coordinates.count)
        routeTrimMap.stretch.picked = picked
        return picked
    }

    /// Everything of this file's that is on the map, to take off it.
    func routeStretchOverlays() -> [MKPolyline] {
        let state = routeTrimMap.stretch
        return [state.picked, state.pullCover, state.pullBand].compactMap(\.self)
    }

    func forgetRouteStretchOverlays() {
        routeTrimMap.stretch.picked = nil
        routeTrimMap.stretch.pullCover = nil
        routeTrimMap.stretch.pullBand = nil
        routeTrimMap.stretch.pulled = nil
        routeTrimMap.stretch.pulledOn = nil
    }

    /// The renderer for one of this file's polylines, or `nil` for any other.
    func routeStretchRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        let state = routeTrimMap.stretch
        if state.pullCover === polyline { return routeTrimCoverRenderer(for: polyline) }
        let isPicked = state.picked === polyline
        guard isPicked || state.pullBand === polyline else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor.systemOrange
        #else
        renderer.strokeColor = UIColor.systemOrange
        #endif
        renderer.lineWidth = isPicked ? Self.trimFocusWidth : Self.pullBandWidth
        renderer.lineDashPattern = [3, 5]
        renderer.lineJoin = .round
        renderer.lineCap = .round
        guard isPicked else { return renderer }
        routeTrimMap.stretch.pickedRenderer = renderer
        if let session = routeTrimMap.session, let start = session.spot(of: .start), let end = session.spot(of: .end) {
            cover(renderer, from: start.drawnFraction, to: end.drawnFraction)
        }
        return renderer
    }
}

#if canImport(UIKit)
extension MapView.Coordinator {
    // MARK: A pull

    /// Adds the recognizer that pulls the line. Idempotent, like the
    /// handles' own.
    func installRoutePull(on mapView: MKMapView) {
        guard routeTrimMap.stretch.pullRecognizer == nil else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleRoutePull(_:)))
        recognizer.minimumPressDuration = Self.pullPressDuration
        // The delegate `gestureRecognizerShouldBegin` discriminates on: this
        // one begins only on the line, away from its handles.
        recognizer.delegate = self
        routeTrimMap.stretch.pullRecognizer = recognizer
        mapView.addGestureRecognizer(recognizer)
    }

    @objc func handleRoutePull(_ recognizer: UILongPressGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        switch recognizer.state {
        case .began: beginRoutePull(at: point, in: mapView)
        case .changed: moveRoutePull(to: point, in: mapView)
        case .ended: endRoutePull(at: point, in: mapView)
        case .cancelled, .failed: cancelRoutePull(on: mapView)
        case .possible: break
        @unknown default: cancelRoutePull(on: mapView)
        }
    }

    /// How many metres a point on the map is, where `point` is.
    private func metersPerPoint(at point: CGPoint, in mapView: MKMapView) -> Double {
        let here = MKMapPoint(mapView.convert(point, toCoordinateFrom: mapView))
        let beside = MKMapPoint(mapView.convert(CGPoint(x: point.x + 1, y: point.y), toCoordinateFrom: mapView))
        return here.distance(to: beside)
    }

    /// The stretch a pull at `point` would redraw, if a finger there is on
    /// the line and off its handles.
    func routePullStretch(at point: CGPoint, in mapView: MKMapView) -> ClosedRange<Double>? {
        guard let session = routeTrimMap.session, let line = session.line,
              routeTrimHandle(at: point, in: mapView) == nil
        else { return nil }
        let scale = metersPerPoint(at: point, in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        guard let meters = line.distance(at: coordinate, within: Double(Self.lineTapTolerancePoints) * scale) else {
            return nil
        }
        return session.pullBounds(around: meters, reach: Double(Self.pullReachPoints) * scale)
    }

    /// Takes hold of the line under `point`. Split from the recognizer's own
    /// handler so a suite can reach it, as the handles' is.
    @discardableResult func beginRoutePull(at point: CGPoint, in mapView: MKMapView) -> Bool {
        guard let session = routeTrimMap.session, let line = session.line,
              let stretch = routePullStretch(at: point, in: mapView)
        else { return false }
        let ground = line.coordinates(between: stretch)
        guard ground.count > 1 else { return false }
        let cover = MKPolyline(coordinates: ground, count: ground.count)
        routeTrimMap.stretch.pulled = stretch
        routeTrimMap.stretch.pulledOn = session.stepGround
        routeTrimMap.stretch.pullOrigin = point
        routeTrimMap.stretch.pullCover = cover
        routeTrimMap.stretch.pausedScrolling = mapView.isScrollEnabled
        mapView.isScrollEnabled = false
        mapView.addOverlay(cover, level: .aboveLabels)
        moveRoutePull(to: point, in: mapView)
        HapticMoment.targetHit.play()
        return true
    }

    /// Runs the band from one end of the stretch through the finger to the
    /// other.
    func moveRoutePull(to point: CGPoint, in mapView: MKMapView) {
        guard let cover = routeTrimMap.stretch.pullCover, cover.pointCount > 1 else { return }
        let ends = cover.points()
        let through = mapView.convert(point, toCoordinateFrom: mapView)
        let corners = [ends[0].coordinate, through, ends[cover.pointCount - 1].coordinate]
        let band = MKPolyline(coordinates: corners, count: corners.count)
        if let old = routeTrimMap.stretch.pullBand { mapView.removeOverlay(old) }
        routeTrimMap.stretch.pullBand = band
        mapView.addOverlay(band, level: .aboveLabels)
    }

    /// Lets go: the stretch is drawn through where the finger was lifted,
    /// unless it was lifted where it came down.
    func endRoutePull(at point: CGPoint, in mapView: MKMapView) {
        let state = routeTrimMap.stretch
        guard let session = routeTrimMap.session, let stretch = state.pulled else {
            cancelRoutePull(on: mapView)
            return
        }
        let moved = hypot(point.x - state.pullOrigin.x, point.y - state.pullOrigin.y)
        guard moved > Self.lineTapTolerancePoints else {
            cancelRoutePull(on: mapView)
            return
        }
        releaseRoutePullScrolling(on: mapView)
        let via = mapView.convert(point, toCoordinateFrom: mapView)
        // The band stays while the path is asked for, and goes with the line
        // it was drawn on when the new one arrives — or here, if none does.
        Task { [weak self, weak mapView] in
            let landed = await session.reroute(stretch, through: via, on: state.pulledOn)
            guard !landed, let self, let mapView else { return }
            cancelRoutePull(on: mapView)
        }
    }

    /// Takes the pull off the map and asks for nothing.
    func cancelRoutePull(on mapView: MKMapView) {
        releaseRoutePullScrolling(on: mapView)
        let state = routeTrimMap.stretch
        mapView.removeOverlays([state.pullCover, state.pullBand].compactMap(\.self))
        routeTrimMap.stretch.pullCover = nil
        routeTrimMap.stretch.pullBand = nil
        routeTrimMap.stretch.pulled = nil
        routeTrimMap.stretch.pulledOn = nil
    }

    private func releaseRoutePullScrolling(on mapView: MKMapView) {
        guard routeTrimMap.stretch.pausedScrolling else { return }
        routeTrimMap.stretch.pausedScrolling = false
        mapView.isScrollEnabled = true
    }
}
#endif
