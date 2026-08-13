//
//  TrailGlyphView.swift
//  OpenTrailsShared
//
//  Draws a trail as a stroked line fitted to the view's bounds, with an
//  optional dot at the last-known position — no basemap, no image assets, no
//  network. This is the iOS widget's fallback whenever a rendered basemap
//  isn't available yet:
//  the first seconds after a trail is selected, offline, or if a snapshot
//  render failed. See ``TrailMapView`` for the phone's map-backed version.
//
//  The fit-to-bounds projection here is what makes it a good fallback rather
//  than a degraded one: with no basemap to line up against, the trail is free
//  to fill the whole frame at whatever scale shows it best.
//

import SwiftUI

public struct TrailGlyphView: View {
    private let polyline: [SharedTrailSnapshot.CodableCoordinate]
    private let liveFix: SharedTrailSnapshot.CodableCoordinate?
    private let tint: Color
    private let lineWidth: CGFloat
    private let showsFixDot: Bool

    public init(
        polyline: [SharedTrailSnapshot.CodableCoordinate],
        tint: Color,
        liveFix: SharedTrailSnapshot.CodableCoordinate? = nil,
        lineWidth: CGFloat = 3,
        showsFixDot: Bool = true
    ) {
        self.polyline = polyline
        self.liveFix = liveFix
        self.tint = tint
        self.lineWidth = lineWidth
        self.showsFixDot = showsFixDot
    }

    public var body: some View {
        Canvas { context, size in
            guard polyline.count > 1,
                  let projected = Self.project(polyline: polyline, liveFix: liveFix, into: size, inset: lineWidth * 2)
            else { return }

            TrailStroke.draw(
                points: projected.points,
                liveFixPoint: showsFixDot ? projected.liveFixPoint : nil,
                tint: tint,
                lineWidth: lineWidth,
                casing: false,
                in: &context
            )
        }
    }

    // Minimum cos(latitude) to prevent degenerate near-polar bounding boxes from
    // blowing up the projection scale.
    private static let minCosLat: Double = 0.15
    // Near-zero floor for bounding-box extents, preventing division by zero on
    // single-point or perfectly vertical/horizontal routes.
    private static let minBoundsExtent: Double = 1e-9

    private struct Projected {
        let points: [CGPoint]
        let liveFixPoint: CGPoint?
    }

    /// Projects lat/lon into a 2D shape fitted to `size`, using a simple
    /// equirectangular approximation around the route's own center latitude —
    /// indistinguishable from a true projection at trail scale, and the right
    /// choice here precisely *because* nothing else has to agree with it.
    /// (``TrailMapView``, which must line up with a rendered map, projects
    /// through ``Mercator`` instead.)
    private static func project(
        polyline: [SharedTrailSnapshot.CodableCoordinate],
        liveFix: SharedTrailSnapshot.CodableCoordinate?,
        into size: CGSize,
        inset: CGFloat
    ) -> Projected? {
        guard let first = polyline.first else { return nil }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in polyline {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        let centerLat = (minLat + maxLat) / 2
        // Clamped well away from zero so a degenerate (near-polar, never
        // realistic for a hiking trail) bounding box can't blow up the scale.
        let cosLat = max(cos(centerLat * .pi / 180), Self.minCosLat)

        func flat(_ c: SharedTrailSnapshot.CodableCoordinate) -> CGPoint {
            // Screen y grows downward; latitude grows north, so flip it.
            CGPoint(x: c.longitude * cosLat, y: -c.latitude)
        }

        let rawPoints = polyline.map(flat)
        var minX = rawPoints[0].x, maxX = rawPoints[0].x
        var minY = rawPoints[0].y, maxY = rawPoints[0].y
        for rawPoint in rawPoints {
            minX = min(minX, rawPoint.x); maxX = max(maxX, rawPoint.x)
            minY = min(minY, rawPoint.y); maxY = max(maxY, rawPoint.y)
        }
        let boundsWidth = max(maxX - minX, Self.minBoundsExtent)
        let boundsHeight = max(maxY - minY, Self.minBoundsExtent)
        let availableWidth = max(size.width - inset * 2, 1)
        let availableHeight = max(size.height - inset * 2, 1)
        let scale = min(availableWidth / boundsWidth, availableHeight / boundsHeight)
        let originX = (size.width - boundsWidth * scale) / 2
        let originY = (size.height - boundsHeight * scale) / 2

        func fit(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: originX + (pt.x - minX) * scale, y: originY + (pt.y - minY) * scale)
        }

        return Projected(points: rawPoints.map(fit), liveFixPoint: liveFix.map { fit(flat($0)) })
    }
}

/// The trail line and position dot themselves, once someone else has decided
/// where the points go. Shared by ``TrailGlyphView`` (fit-to-bounds, no
/// basemap) and ``TrailMapView`` (Mercator, registered to a rendered map) so
/// the trail reads identically on every surface regardless of what's under it.
enum TrailStroke {
    private static let casingOpacity: Double = 0.85
    private static let casingWidthBonus: CGFloat = 2.5
    private static let ringDiameterMultiplier: CGFloat = 2.6
    private static let dotDiameterMultiplier: CGFloat = 1.6

    /// - Parameter casing: draws a light halo beneath the line. Off over a
    ///   flat background where it would only add fuzz; on over map imagery,
    ///   where a bare stroke loses contrast the moment it crosses a road or a
    ///   patch of scrub.
    static func draw(
        points: [CGPoint],
        liveFixPoint: CGPoint?,
        tint: Color,
        lineWidth: CGFloat,
        casing: Bool,
        in context: inout GraphicsContext
    ) {
        guard points.count > 1 else { return }

        var path = Path()
        path.addLines(points)

        if casing {
            context.stroke(
                path,
                with: .color(.white.opacity(casingOpacity)),
                style: StrokeStyle(lineWidth: lineWidth + casingWidthBonus, lineCap: .round, lineJoin: .round)
            )
        }
        context.stroke(
            path,
            with: .color(tint),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )

        guard let dot = liveFixPoint else { return }
        let ringDiameter = lineWidth * ringDiameterMultiplier
        let dotDiameter = lineWidth * dotDiameterMultiplier
        let ringRect = CGRect(
            x: dot.x - ringDiameter / 2,
            y: dot.y - ringDiameter / 2,
            width: ringDiameter,
            height: ringDiameter
        )
        let dotRect = CGRect(
            x: dot.x - dotDiameter / 2,
            y: dot.y - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        context.fill(Path(ellipseIn: ringRect), with: .color(.white))
        context.fill(Path(ellipseIn: dotRect), with: .color(tint))
    }
}

#Preview {
    TrailGlyphView(
        polyline: [
            .init(latitude: 37.3349, longitude: -122.0090),
            .init(latitude: 37.3372, longitude: -122.0060),
            .init(latitude: 37.3358, longitude: -122.0020),
            .init(latitude: 37.3400, longitude: -122.0005),
        ],
        tint: .green,
        liveFix: .init(latitude: 37.3372, longitude: -122.0060),
        lineWidth: 4
    )
    .frame(width: 160, height: 160)
    .padding()
}
