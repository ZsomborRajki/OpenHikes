//
//  MapRouteTrim+KeptLine.swift
//  OpenHikes
//
//  The kept line *Edit Route* draws itself, where the hike's own line on the
//  map is not the kept one — see `MapRouteTrim.swift`.
//
//  ## Cut at its pauses
//
//  A pause is not trail (see ``RouteBoundary``), and the route itself is
//  stroked run by run with each paused leg dotted between them (see
//  `DirectionalPolylineRenderer+Pauses.swift`). One solid stroke of the
//  whole line laid over that would draw a drive Auto-Pause stopped for as
//  trail again, and would draw it where the hike's own line has none at all:
//  over ground an earlier trim cut off. So the kept line is one polyline for
//  each walked run, in the route's colour, and one for each paused leg, in
//  the pause's own style (`applyPausedStyle(to:)`), the pieces
//  ``TrailRuns`` cuts every surface's line into.
//
//  ## Each piece stroked between the cuts
//
//  The cuts are fractions of the whole line as MapKit measures it
//  (``RouteTrimLine/drawnFractions``). A piece takes up a span of those, and
//  within a piece MapKit measures in the same map points, so the part of a
//  piece between the cuts is the cuts' fractions read across its span. A
//  drag then rewrites the two pieces the cuts stand on, and every other
//  piece is either whole or hidden, which it already was.
//

import MapKit
import OpenHikesData
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One piece of the kept line: a walked run, or a paused leg between two.
struct RouteTrimKeptPiece {
    let polyline: MKPolyline
    let isPaused: Bool
    /// Where the piece begins and ends along the whole line, 0 to 1 — see
    /// ``RouteTrimLine/drawnFractions``.
    let span: ClosedRange<Double>
    /// Set when MapKit asks for it, after the overlay is added.
    weak var renderer: MKPolylineRenderer?

    /// How far along the piece the spot `fraction` of the whole line is, 0
    /// to 1: before it is its beginning, past it its end.
    func fraction(of fraction: Double) -> Double {
        let length = span.upperBound - span.lowerBound
        guard length > 0 else { return fraction > span.lowerBound ? 1 : 0 }
        return min(max((fraction - span.lowerBound) / length, 0), 1)
    }
}

extension MapView.Coordinator {
    /// The kept line of `line`, cut at its pauses — see the file header.
    static func keptPieces(of line: RouteTrimLine) -> [RouteTrimKeptPiece] {
        let runs = line.route.trailRuns
        let walked = runs.walkedRuns.map { run in
            keptPiece(of: line, points: run.lowerBound...(run.upperBound - 1), isPaused: false)
        }
        let paused = runs.pausedLegs.map { leg in keptPiece(of: line, points: leg...(leg + 1), isPaused: true) }
        return walked + paused
    }

    private static func keptPiece(
        of line: RouteTrimLine,
        points: ClosedRange<Int>,
        isPaused: Bool
    ) -> RouteTrimKeptPiece {
        let coordinates = Array(line.profile.coordinates[points])
        return RouteTrimKeptPiece(
            polyline: MKPolyline(coordinates: coordinates, count: coordinates.count),
            isPaused: isPaused,
            span: line.drawnFractions[points.lowerBound]...line.drawnFractions[points.upperBound]
        )
    }

    /// Strokes the part of `piece` between the two cuts.
    func coverKept(
        _ piece: RouteTrimKeptPiece,
        with renderer: MKPolylineRenderer,
        from start: RouteTrimLine.Spot,
        to end: RouteTrimLine.Spot
    ) {
        cover(renderer, from: piece.fraction(of: start.drawnFraction), to: piece.fraction(of: end.drawnFraction))
    }

    /// The renderer for a piece of the kept line, or `nil` for any other
    /// polyline: a run in the route's own colour and width, a paused leg as
    /// the route's own pauses are drawn.
    func routeTrimKeptRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        guard let index = routeTrimMap.keptPieces.firstIndex(where: { $0.polyline === polyline }) else { return nil }
        let piece = routeTrimMap.keptPieces[index]
        let renderer = MKPolylineRenderer(polyline: polyline)
        if piece.isPaused {
            applyPausedStyle(to: renderer)
        } else {
            #if os(macOS)
            renderer.strokeColor = NSColor(routeTint).withAlphaComponent(1)
            #else
            renderer.strokeColor = UIColor(routeTint).withAlphaComponent(1)
            #endif
            renderer.lineWidth = CGFloat(routeWidth)
            renderer.lineJoin = .round
            renderer.lineCap = .round
        }
        routeTrimMap.keptPieces[index].renderer = renderer
        // The cuts it is drawn to, which the pass that added the overlay
        // could not set: MapKit asks for the renderer afterwards.
        if let session = routeTrimMap.session,
           let start = session.keptSpot(of: .start), let end = session.keptSpot(of: .end) {
            coverKept(piece, with: renderer, from: start, to: end)
        }
        return renderer
    }
}
