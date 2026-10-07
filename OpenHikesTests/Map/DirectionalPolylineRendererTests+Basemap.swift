//
//  DirectionalPolylineRendererTests+Basemap.swift
//  OpenHikesTests
//
//  The line drawn over a map rather than over nothing. MapKit draws every
//  overlay at the line's level into one shared tile, the basemap's tiles
//  first, so a pass that clears or copies pixels reaches the map under the
//  line, not just the line. The other bitmap tests draw into an empty canvas,
//  where a cleared pixel and an untouched one look the same — and a dashed
//  route coloured by steepness showed white in every gap on a device while
//  all of them passed. These fill the canvas with an opaque "map" first and
//  ask that none of it is left see-through.
//
//  Split from ``DirectionalPolylineRendererTests`` as an extension: one suite
//  per file, and the bitmap helpers are that suite's.
//

import CoreGraphics
import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing
import UIKit

extension DirectionalPolylineRendererTests {
    private static let basemapLatitude = 47.6
    private static let basemapLongitude = 12.9
    private static let basemapStart = MKMapPoint(
        CLLocationCoordinate2D(latitude: basemapLatitude, longitude: basemapLongitude)
    )
    private static let basemapLength = 400.0
    private static let basemapMargin = 20.0
    private static let basemapSpacing = 10.0

    private static func basemapPoints(_ from: Double, _ to: Double) -> [MKMapPoint] {
        let perMeter = MKMapPointsPerMeterAtLatitude(basemapLatitude)
        return stride(from: from, through: to, by: basemapSpacing).map { meters in
            MKMapPoint(x: basemapStart.x + meters * perMeter, y: basemapStart.y)
        }
    }

    private static func basemapStretch(
        _ from: Double,
        _ to: Double,
        _ color: CGColor
    ) -> DirectionalPolylineRenderer.Shade {
        let points = basemapPoints(from, to)
        return .init(polyline: MKPolyline(points: points, count: points.count), color: color)
    }

    /// Draws a line in `pattern` east along a parallel over a canvas painted
    /// opaque grey first, styled as the map coordinator styles it, with a
    /// black border and `shades` over it — wide enough on the canvas that a
    /// dash and its gap are many pixels long.
    private static func renderOverBasemap(
        _ pattern: RouteLinePattern,
        shades: [DirectionalPolylineRenderer.Shade],
        stroke: UIColor = .blue
    ) throws -> Canvas {
        let whole = basemapPoints(0, basemapLength)
        let polyline = MKPolyline(points: whole, count: whole.count)
        let renderer = renderer(pattern, on: polyline)
        renderer.strokeColor = stroke
        let dashes = pattern.dashLengths(forWidth: Double(renderer.lineWidth))
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
        renderer.lineCap = pattern.lineCap
        renderer.lineJoin = .round
        renderer.borderColor = CGColor(gray: 0, alpha: 1)
        renderer.setShades(shades)

        let canvas = try Canvas()
        canvas.context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        canvas.context.fill(CGRect(x: 0, y: 0, width: canvas.context.width, height: canvas.context.height))
        let perMeter = MKMapPointsPerMeterAtLatitude(basemapLatitude)
        let shown = (basemapLength + basemapMargin * 2) * perMeter
        let zoom = CGFloat(Double(canvas.context.width) / shown)
        let rect = MKMapRect(
            x: basemapStart.x - basemapMargin * perMeter,
            y: basemapStart.y - shown / 2,
            width: shown,
            height: shown
        )
        canvas.context.scaleBy(x: zoom, y: zoom)
        canvas.context.translateBy(
            x: polyline.boundingMapRect.origin.x - rect.origin.x,
            y: polyline.boundingMapRect.origin.y - rect.origin.y
        )
        renderer.draw(rect, zoomScale: zoom, in: canvas.context)
        return canvas
    }

    /// Below this alpha a pixel is map the line took away. Not 255: where a
    /// pass clears a stroke and the next paints the same stroke back, the
    /// edge's anti-aliased pixels come out no less than three-quarters
    /// opaque — `c + (1 - c)²` of a pixel the stroke covers by `c` — and a
    /// hole is half opaque at most.
    private static let seeThrough: UInt8 = 180

    /// Pixels the draw left see-through.
    private static func seeThroughPixels(in canvas: Canvas) -> Int {
        guard let data = canvas.context.data else { return 0 }
        let count = canvas.context.width * canvas.context.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        return (0..<count).count { bytes[$0 * 4 + 3] < seeThrough }
    }

    /// The alpha of the translucent lines.
    private static let translucent: CGFloat = 0.5

    /// Two stretches meeting half way, so a blend is drawn between them too.
    private static func meetingShades(alpha: CGFloat) -> [DirectionalPolylineRenderer.Shade] {
        let half = basemapLength / 2
        return [
            basemapStretch(0, half, CGColor(red: 1, green: 0, blue: 0, alpha: alpha)),
            basemapStretch(half, basemapLength, CGColor(red: 0, green: 1, blue: 0, alpha: alpha)),
        ]
    }

    @Test(
        "a dashed or dotted coloured line leaves the map showing in its gaps",
        arguments: [RouteLinePattern.dashed, .dotted]
    )
    func brokenColouredLineKeepsTheMap(_ pattern: RouteLinePattern) throws {
        let canvas = try Self.renderOverBasemap(pattern, shades: Self.meetingShades(alpha: 1))
        #expect(Self.seeThroughPixels(in: canvas) == 0, "the gaps were cleared through to nothing")
    }

    @Test("a translucent coloured line is laid over the map rather than replacing it")
    func translucentColouredLineKeepsTheMap() throws {
        let canvas = try Self.renderOverBasemap(
            .solid,
            shades: Self.meetingShades(alpha: Self.translucent),
            stroke: UIColor.blue.withAlphaComponent(Self.translucent)
        )
        #expect(Self.seeThroughPixels(in: canvas) == 0, "the stretches were copied over the map")
    }

    @Test("a translucent bordered line shows the map inside its border")
    func translucentBorderedLineKeepsTheMap() throws {
        let canvas = try Self.renderOverBasemap(
            .solid,
            shades: [],
            stroke: UIColor.blue.withAlphaComponent(Self.translucent)
        )
        #expect(Self.seeThroughPixels(in: canvas) == 0, "the border's middle was cleared through the map")
    }

    /// Where a dashed line's colours meet, the gradient takes over the
    /// stretches' own dashes rather than drawing dashes of its own: drawn
    /// as its own, they fell between the stretches' and cut slits through
    /// them, and left the stretches' outlines standing round nothing. So
    /// the line is inked in exactly the places it is when both stretches
    /// are one colour and there is nothing to blend.
    @Test("a dashed line blends its colours on its own dashes")
    func dashedBlendKeepsTheDashes() throws {
        let half = Self.basemapLength / 2
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blended = try Self.renderOverBasemap(.dashed, shades: Self.meetingShades(alpha: 1))
        let unblended = try Self.renderOverBasemap(
            .dashed,
            shades: [
                Self.basemapStretch(0, half, red),
                Self.basemapStretch(half, Self.basemapLength, red),
            ]
        )
        let row = blended.context.height / 2
        let differing = (0..<blended.context.width).count { column in
            Self.isGrey(Self.basemapPixel(in: blended, x: column, y: row))
                != Self.isGrey(Self.basemapPixel(in: unblended, x: column, y: row))
        }
        #expect(differing == 0, "the blend moved where the dashes are")
    }

    /// Whether a pixel is the canvas's own grey — the "map" — rather than
    /// anything the line drew.
    private static func isGrey(_ pixel: (red: UInt8, green: UInt8, blue: UInt8)) -> Bool {
        let tolerance = 24
        let grey = 128
        return [pixel.red, pixel.green, pixel.blue].allSatisfy { abs(Int($0) - grey) <= tolerance }
    }

    private static func basemapPixel(in canvas: Canvas, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard let data = canvas.context.data else { return (0, 0, 0) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: canvas.context.width * canvas.context.height * 4)
        let base = (y * canvas.context.width + x) * 4
        return (bytes[base], bytes[base + 1], bytes[base + 2])
    }

    /// The case every hike starts in, which needs no layer and has to come
    /// out the same without one.
    @Test("a solid opaque coloured line keeps the map without a layer")
    func solidColouredLineKeepsTheMap() throws {
        let canvas = try Self.renderOverBasemap(.solid, shades: Self.meetingShades(alpha: 1))
        #expect(Self.seeThroughPixels(in: canvas) == 0)
    }
}
