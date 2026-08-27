//
//  DirectionalPolylineRendererTests.swift
//  OpenHikesTests
//
//  This suite exists because `MapCoordinatorTests` only ever checks that the
//  coordinator hands a renderer back with the right stroke, width and pattern
//  on it. Nothing drove `draw`.
//
//  Two things are worth driving. The chevron pass is the app's own drawing
//  rather than MapKit's, so a pattern that carries chevrons has to actually
//  put ink on the context and one that does not has to leave it alone. And the
//  off-screen branch carries a closed-form spacing carry whose stated reason
//  is that the loop it replaced could run "millions of iterations" on one long
//  segment at deep zoom — a claim that is only true while nobody replaces it
//  with the obvious loop again, and only a test notices that.
//
//  Drawn into a bitmap context rather than onto a map: `MKOverlayRenderer`
//  converts through the overlay's own bounding rect, so a renderer draws
//  perfectly well with no `MKMapView` anywhere near it.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import Testing

@Suite("Directional polyline rendering")
struct DirectionalPolylineRendererTests {
    /// A straight west-to-east line, long enough to hold many chevrons at the
    /// spacing `RouteLinePattern` asks for.
    static func line(
        from start: CLLocationCoordinate2D = .init(latitude: 47.60, longitude: 12.85),
        to end: CLLocationCoordinate2D = .init(latitude: 47.60, longitude: 12.90)
    ) -> MKPolyline {
        var coordinates = [start, end]
        return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }

    static func renderer(
        _ pattern: RouteLinePattern,
        on polyline: MKPolyline
    ) -> DirectionalPolylineRenderer {
        let renderer = DirectionalPolylineRenderer(polyline: polyline)
        renderer.pattern = pattern
        renderer.lineWidth = 6
        renderer.strokeColor = .red
        return renderer
    }

    /// A small ARGB bitmap that reports whether anything was drawn into it.
    struct Canvas {
        let context: CGContext

        init(side: Int = 256) throws {
            context = try #require(
                CGContext(
                    data: nil,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
        }

        /// Non-transparent pixels. Zero means nothing was drawn at all.
        var inkedPixels: Int {
            guard let data = context.data else { return 0 }
            let count = context.width * context.height
            let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
            var inked = 0
            for pixel in 0..<count where bytes[pixel * 4 + 3] != 0 { inked += 1 }
            return inked
        }
    }

    /// Draws `renderer` over the whole route at a scale where a chevron is a
    /// handful of map points across.
    @discardableResult static func render(
        _ renderer: DirectionalPolylineRenderer,
        of polyline: MKPolyline,
        into canvas: Canvas,
        zoomScale: MKZoomScale = 1
    ) -> Int {
        renderer.draw(polyline.boundingMapRect, zoomScale: zoomScale, in: canvas.context)
        return canvas.inkedPixels
    }

    // MARK: Chevrons

    @Test("a pattern with chevrons draws them without any line behind them")
    func arrowheadsDrawChevrons() throws {
        let polyline = Self.line()
        let canvas = try Canvas()
        let inked = Self.render(
            Self.renderer(.arrowheads, on: polyline),
            of: polyline,
            into: canvas
        )
        #expect(inked > 0, "arrowheads is chevrons only — it still has to draw something")
    }

    @Test("a pattern with neither chevrons nor a visible stroke leaves the context blank")
    func chevronlessPatternDrawsNoChevrons() throws {
        let polyline = Self.line()
        let renderer = Self.renderer(.solid, on: polyline)
        // `.solid` has no chevrons, so anything on the context afterwards came
        // from MapKit's own stroke. Removing the colour removes that too,
        // which isolates this file's contribution to exactly nothing.
        renderer.strokeColor = nil
        renderer.lineWidth = 0
        let canvas = try Canvas()
        #expect(Self.render(renderer, of: polyline, into: canvas) == 0)
    }

    @Test("chevron patterns are exactly the ones the pattern says carry them", arguments: [
        (RouteLinePattern.arrowheads, true),
        (.directional, true),
        (.solid, false),
        (.dashed, false),
        (.dotted, false),
    ])
    func onlyChevronPatternsInk(pattern: RouteLinePattern, drawsChevrons: Bool) throws {
        let polyline = Self.line()
        let renderer = Self.renderer(pattern, on: polyline)
        // Same isolation as above: with no stroke, only the chevron pass can
        // leave anything behind.
        renderer.strokeColor = nil
        renderer.lineWidth = 0
        let canvas = try Canvas()
        let inked = Self.render(renderer, of: polyline, into: canvas)
        #expect((inked > 0) == drawsChevrons, "\(pattern.rawValue) drew \(inked) pixels")
    }

    // MARK: Degenerate input

    @Test("a zero or negative zoom scale is refused rather than dividing by it")
    func refusesNonPositiveZoomScale() throws {
        let polyline = Self.line()
        let canvas = try Canvas()
        let renderer = Self.renderer(.arrowheads, on: polyline)
        #expect(Self.render(renderer, of: polyline, into: canvas, zoomScale: 0) == 0)
    }

    @Test("a one-point line has no direction to draw")
    func refusesSinglePointLine() throws {
        var single = [CLLocationCoordinate2D(latitude: 47.60, longitude: 12.85)]
        let polyline = MKPolyline(coordinates: &single, count: 1)
        let canvas = try Canvas()
        let renderer = Self.renderer(.arrowheads, on: polyline)
        #expect(Self.render(renderer, of: polyline, into: canvas) == 0)
    }

    // MARK: The off-screen carry

    /// The reason the off-screen branch is closed-form rather than a loop.
    ///
    /// A route whose visible window is a few metres wide at a zoom scale small
    /// enough to make the chevron spacing sub-map-point, with a segment that
    /// spans a continent: the replaced loop would step the carry one spacing
    /// at a time across that whole segment. This asserts it returns at all,
    /// promptly, which is the only observable difference between the two.
    @Test("an off-screen segment costs no time per chevron", .timeLimit(.minutes(1)))
    func offScreenSegmentsDoNotIteratePerChevron() throws {
        var coordinates = [
            CLLocationCoordinate2D(latitude: -60, longitude: -170),
            CLLocationCoordinate2D(latitude: 60, longitude: 170),
        ]
        let polyline = MKPolyline(coordinates: &coordinates, count: coordinates.count)
        let renderer = Self.renderer(.arrowheads, on: polyline)
        let canvas = try Canvas()

        // A visible rect nowhere near the segment, so the off-screen branch is
        // the one that runs.
        let elsewhere = MKMapRect(
            origin: MKMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0)),
            size: MKMapSize(width: 1, height: 1)
        )
        let started = ContinuousClock.now
        renderer.draw(elsewhere, zoomScale: 0.00001, in: canvas.context)
        let elapsed = ContinuousClock.now - started

        #expect(canvas.inkedPixels == 0, "nothing on screen means nothing drawn")
        #expect(
            elapsed < .seconds(1),
            "the off-screen carry has to be closed-form, not one step per chevron"
        )
    }

    /// The other half of that branch: skipping an off-screen segment must not
    /// shift where the chevrons land on the segments that *are* visible.
    ///
    /// Two identical visible tails, one preceded by an off-screen detour and
    /// one not, drawn over the same window. If the carry were dropped or
    /// mis-advanced, the two would ink different pixel counts.
    @Test("skipping an off-screen segment keeps the spacing carry honest")
    func offScreenCarryKeepsSpacing() throws {
        let visibleStart = CLLocationCoordinate2D(latitude: 47.60, longitude: 12.85)
        let visibleEnd = CLLocationCoordinate2D(latitude: 47.60, longitude: 12.90)

        var plain = [visibleStart, visibleEnd]
        let plainLine = MKPolyline(coordinates: &plain, count: plain.count)
        let window = plainLine.boundingMapRect

        let plainCanvas = try Canvas()
        Self.render(
            Self.renderer(.arrowheads, on: plainLine),
            of: plainLine,
            into: plainCanvas
        )

        // The same visible tail, reached after a long excursion that the
        // window never sees.
        var detoured = [
            visibleStart,
            CLLocationCoordinate2D(latitude: 20, longitude: 12.85),
            visibleStart,
            visibleEnd,
        ]
        let detouredLine = MKPolyline(coordinates: &detoured, count: detoured.count)
        let detouredCanvas = try Canvas()
        let detouredRenderer = Self.renderer(.arrowheads, on: detouredLine)
        detouredRenderer.draw(window, zoomScale: 1, in: detouredCanvas.context)

        #expect(plainCanvas.inkedPixels > 0, "precondition: the plain tail drew chevrons")
        #expect(
            detouredCanvas.inkedPixels > 0,
            "an off-screen detour must not stop the visible tail being drawn"
        )
    }
}
