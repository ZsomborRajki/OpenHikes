//
//  DirectionalPolylineRendererTests+Pauses.swift
//  OpenHikesTests
//
//  The route line, cut where the walk was paused (#1034). A paused leg is not
//  trail (#962), but the line was stroked straight across it in the hike's
//  own tint, border and chevrons, with the dotted pause on top, so a drive
//  between two walked pieces read as trail. These draw a three-leg line with
//  its middle leg paused and look for ink along that leg.
//
//  Split from ``DirectionalPolylineRendererTests`` as an extension: one suite
//  per file, and the bitmap helpers are that suite's.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

// swiftlint:disable no_magic_numbers

extension DirectionalPolylineRendererTests {
    /// Where the line's points fall, in map points from its start along a
    /// constant latitude — and so, at a zoom scale of one, in canvas columns.
    /// The middle leg, from 80 to 170, is the paused one.
    private static let pausedLineColumns: [Double] = [0, 80, 170, 250]

    private static func pausedLineCoordinates() -> [CLLocationCoordinate2D] {
        let start = MKMapPoint(CLLocationCoordinate2D(latitude: 47.60, longitude: 12.85))
        return pausedLineColumns.map { MKMapPoint(x: start.x + $0, y: start.y).coordinate }
    }

    private static func polyline(_ coordinates: [CLLocationCoordinate2D]) -> MKPolyline {
        MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    /// The renderer as the map coordinator hands it a paused route: cut into
    /// the two runs either side of the middle leg.
    private static func cut(_ renderer: DirectionalPolylineRenderer, _ coordinates: [CLLocationCoordinate2D]) {
        renderer.setRuns(
            [polyline(Array(coordinates[0...1])), polyline(Array(coordinates[2...3]))],
            pausedLegs: [1]
        )
    }

    /// Drawn across the middle of the canvas, for the reason the border's
    /// tests are: a line of constant latitude sits on the renderer's y = 0.
    private static func drawCentered(
        _ renderer: DirectionalPolylineRenderer,
        of polyline: MKPolyline
    ) throws -> Canvas {
        let canvas = try Canvas()
        canvas.context.translateBy(x: 0, y: CGFloat(canvas.context.height / 2))
        renderer.draw(polyline.boundingMapRect, zoomScale: 1, in: canvas.context)
        return canvas
    }

    /// Columns well inside each leg, clear of the round caps and joins at its
    /// ends, which reach half the line's width past them.
    private static let walkedColumns = [40, 210]
    private static let pausedColumns = [100, 125, 150]

    @Test("an uncut line is stroked straight across every leg", arguments: [RouteLinePattern.solid, .directional])
    func uncutLineInksEveryLeg(pattern: RouteLinePattern) throws {
        let coordinates = Self.pausedLineCoordinates()
        let line = Self.polyline(coordinates)
        let canvas = try Self.drawCentered(Self.renderer(pattern, on: line), of: line)
        for column in Self.walkedColumns + Self.pausedColumns {
            #expect(canvas.inkedRows(inColumn: column) > 0, "column \(column)")
        }
    }

    /// The line, its border and its chevrons all leave the paused leg alone:
    /// the dotted overlay drawn there is a separate overlay, and nothing of
    /// the trail's own may sit under it.
    @Test(
        "a paused leg is left empty by the line, its border and its chevrons, and the walked runs still draw",
        arguments: [RouteLinePattern.solid, .directional, .dashed, .arrowheads]
    )
    func pausedLegIsLeftEmpty(pattern: RouteLinePattern) throws {
        let coordinates = Self.pausedLineCoordinates()
        let line = Self.polyline(coordinates)
        let renderer = Self.renderer(pattern, on: line)
        let dashes = pattern.dashLengths(forWidth: Double(renderer.lineWidth))
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
        renderer.lineCap = pattern.lineCap
        renderer.borderColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        Self.cut(renderer, coordinates)

        let canvas = try Self.drawCentered(renderer, of: line)
        for column in Self.pausedColumns {
            #expect(canvas.inkedRows(inColumn: column) == 0, "\(pattern.rawValue) inked the pause at \(column)")
        }
        #expect(
            Self.walkedColumns.contains { canvas.inkedRows(inColumn: $0) > 0 },
            "\(pattern.rawValue) drew nothing of the walked runs"
        )
    }

    /// A restyle after the first draw reaches the runs' copies too, which are
    /// built once and kept: a colour dragged to nothing takes the runs with it.
    @Test("restyling a cut line restyles its runs")
    func restyleReachesTheRuns() throws {
        let coordinates = Self.pausedLineCoordinates()
        let line = Self.polyline(coordinates)
        let renderer = Self.renderer(.solid, on: line)
        Self.cut(renderer, coordinates)
        #expect(try Self.drawCentered(renderer, of: line).inkedRows(inColumn: 40) > 0)

        renderer.strokeColor = .clear
        #expect(try Self.drawCentered(renderer, of: line).inkedRows(inColumn: 40) == 0)
    }

    @Test("handing the line no paused legs strokes it whole again")
    func uncuttingRestoresTheWholeLine() throws {
        let coordinates = Self.pausedLineCoordinates()
        let line = Self.polyline(coordinates)
        let renderer = Self.renderer(.solid, on: line)
        Self.cut(renderer, coordinates)
        renderer.setRuns([], pausedLegs: [])

        #expect(!renderer.isCut)
        #expect(try Self.drawCentered(renderer, of: line).inkedRows(inColumn: 125) > 0)
    }
}

// swiftlint:enable no_magic_numbers
