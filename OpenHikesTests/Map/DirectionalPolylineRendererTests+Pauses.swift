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
import UIKit

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
        // Every walked column where the pattern strokes a solid line, so a
        // run that is missing or drawn in the wrong place shows; a dash or a
        // chevron may fall either side of one column.
        let inked = Self.walkedColumns.filter { canvas.inkedRows(inColumn: $0) > 0 }
        if pattern.drawsLine, dashes.isEmpty {
            #expect(inked == Self.walkedColumns, "\(pattern.rawValue) left a walked run undrawn")
        } else {
            #expect(!inked.isEmpty, "\(pattern.rawValue) drew nothing of the walked runs")
        }
    }

    /// A restyle after the first draw reaches the runs' copies too, which are
    /// built once and kept: a colour dragged to nothing takes the runs with it.
    @Test("restyling a cut line restyles its runs")
    func restyleReachesTheRuns() throws {
        let coordinates = Self.pausedLineCoordinates()
        let line = Self.polyline(coordinates)
        let renderer = Self.renderer(.solid, on: line)
        Self.cut(renderer, coordinates)
        let drawn = try Self.drawCentered(renderer, of: line)
        #expect(Self.walkedColumns.allSatisfy { drawn.inkedRows(inColumn: $0) > 0 })

        renderer.strokeColor = .clear
        let restyled = try Self.drawCentered(renderer, of: line)
        #expect(Self.walkedColumns.allSatisfy { restyled.inkedRows(inColumn: $0) == 0 })
    }

    // MARK: Runs over each other

    /// An out-and-back paused at the top, laid flat: walked out from 0 to
    /// 180, paused back to 80, and walked on to 250, so the two runs lie over
    /// each other from 80 to 180. Column 40 is the first run alone, 215 the
    /// second alone and 130 both.
    private static let retracedColumns: [Double] = [0, 180, 80, 250]

    /// The retraced line, cut at its pause, in half-alpha blue with a black
    /// border at `borderAlpha`, or none.
    private static func retraced(borderAlpha: CGFloat?) -> (renderer: DirectionalPolylineRenderer, line: MKPolyline) {
        let start = MKMapPoint(CLLocationCoordinate2D(latitude: 47.60, longitude: 12.85))
        let coordinates = retracedColumns.map { MKMapPoint(x: start.x + $0, y: start.y).coordinate }
        let line = polyline(coordinates)
        let renderer = Self.renderer(.solid, on: line)
        renderer.strokeColor = UIColor.blue.withAlphaComponent(0.5)
        renderer.lineCap = RouteLinePattern.solid.lineCap
        renderer.lineJoin = .round
        renderer.borderColor = borderAlpha.map { CGColor(gray: 0, alpha: $0) }
        cut(renderer, coordinates)
        return (renderer, line)
    }

    /// Drawn across the middle of the canvas, as ``drawCentered(_:of:)``
    /// draws, but over a rect the canvas's size, as MapKit draws a tile,
    /// rather than over the line's own rect: a line of constant latitude has
    /// a rect of no height, and a layer bounded by that covers nothing. Over
    /// `basemap` painted across the whole canvas first, when there is one.
    private static func drawAsTile(
        _ renderer: DirectionalPolylineRenderer,
        of polyline: MKPolyline,
        over basemap: CGColor? = nil
    ) throws -> Canvas {
        let canvas = try Canvas()
        if let basemap {
            canvas.context.setFillColor(basemap)
            canvas.context.fill(CGRect(x: 0, y: 0, width: canvas.context.width, height: canvas.context.height))
        }
        let half = Double(canvas.context.height / 2)
        canvas.context.translateBy(x: 0, y: CGFloat(half))
        let origin = polyline.boundingMapRect.origin
        let tile = MKMapRect(x: origin.x, y: origin.y - half, width: Double(canvas.context.width), height: half * 2)
        renderer.draw(tile, zoomScale: 1, in: canvas.context)
        return canvas
    }

    /// MapKit strokes the whole line as one path, which paints the places it
    /// lies over itself once. Stroked run by run, the way home was laid over
    /// the way out: a half-alpha line came out three-quarters opaque where
    /// they meet, a translucent border the same, and the second run's border
    /// round its start showed through the first run's line, which had been
    /// cleared of its own border before the second was drawn.
    ///
    /// - Parameter borderAlpha: no border, the default opaque one, and a
    ///   translucent one, whose rings lie over each other where the runs do.
    @Test(
        "a translucent line that retraces itself across a pause is drawn as one line where its runs meet",
        arguments: [nil, 1, 0.5] as [CGFloat?]
    )
    func retracedRunsKeepTheLinesAlpha(borderAlpha: CGFloat?) throws {
        let (renderer, line) = Self.retraced(borderAlpha: borderAlpha)
        let canvas = try Self.drawAsTile(renderer, of: line)
        let middle = canvas.context.height / 2
        let alone = canvas.pixel(x: 40, row: middle)
        #expect(abs(Int(alone[3]) - 128) <= 8, "one run alone has to be the line's own alpha, \(alone)")
        let differing = (0..<canvas.context.height).filter { row in
            canvas.pixel(x: 130, row: row) != canvas.pixel(x: 40, row: row)
        }
        #expect(differing.isEmpty, "rows \(differing) are drawn otherwise where the runs lie over each other")
        let showing = (8...242).filter { canvas.pixel(x: $0, row: middle) != alone }
        #expect(showing.isEmpty, "columns \(showing) along the line's middle show something other than the line")
    }

    /// The same line over a map. MapKit draws every overlay at the line's
    /// level into one tile, the basemap's tiles first (see `+Basemap`), so a
    /// `.copy` or a `.clear` outside a layer of the line's own replaces or
    /// erases the map under it. On an empty canvas a pixel erased and then
    /// painted once looks the same as one painted once over the map, so this
    /// paints the canvas opaque grey first and asks for the colours a
    /// translucent line laid over the map has.
    ///
    /// - Parameter borderAlpha: as ``retracedRunsKeepTheLinesAlpha(borderAlpha:)``
    ///   takes it.
    @Test(
        "a translucent line that retraces itself across a pause is laid over the map rather than in place of it",
        arguments: [nil, 1, 0.5] as [CGFloat?]
    )
    func retracedRunsKeepTheMap(borderAlpha: CGFloat?) throws {
        let (renderer, line) = Self.retraced(borderAlpha: borderAlpha)
        let canvas = try Self.drawAsTile(renderer, of: line, over: CGColor(gray: 0.5, alpha: 1))
        let middle = canvas.context.height / 2
        // The top row is nowhere near the line: the map as it was painted.
        let map = canvas.pixel(x: 0, row: 0)
        #expect(map[3] == 255, "the map has to be opaque for the comparison to mean anything, \(map)")
        let gray = Double(map[0])
        // `color` at `alpha` laid over the map, as the bitmap stores it.
        let over = { (color: [Double], alpha: Double) in color.map { $0 * alpha + gray * (1 - alpha) } + [255] }
        let close = { (pixel: [UInt8], expected: [Double]) in
            zip(pixel, expected).allSatisfy { abs(Double($0) - $1) <= 3 }
        }

        // The line and its ring take these rows: a line six points wide
        // straddling the middle, and a two-point border round it.
        let half = Int(renderer.lineWidth / 2)
        let ring = Int(RouteBorder.width(forLineWidth: Double(renderer.lineWidth)))
        let lineRows = (middle - half)..<(middle + half)
        let away = (0..<canvas.context.height).filter { abs($0 - middle) > half + ring + 2 }
        let lost = away.filter { row in (0..<canvas.context.width).contains { canvas.pixel(x: $0, row: row) != map } }
        #expect(lost.isEmpty, "rows \(lost), away from the line, no longer show the map")

        // Blue at half alpha over the grey, where one run is alone (40 and
        // 215) and where both lie (130), and nothing else along the middle.
        let blue = over([0, 0, 255], 0.5)
        for column in [40, 130, 215] {
            let pixel = canvas.pixel(x: column, row: middle)
            #expect(close(pixel, blue), "column \(column) drew \(pixel) where blue over the map is \(blue)")
        }
        let off = (8...242).filter { !close(canvas.pixel(x: $0, row: middle), blue) }
        #expect(off.isEmpty, "columns \(off) along the line's middle are not blue over the map")
        #expect(lineRows.allSatisfy { close(canvas.pixel(x: 130, row: $0), blue) }, "the overlap's rows are not")

        // The ring just outside the line: black at the border's alpha over
        // the grey, alone and where the runs lie over each other.
        guard let borderAlpha else { return }
        let border = over([0, 0, 0], Double(borderAlpha))
        let ringRows = Array((lineRows.lowerBound - ring)..<lineRows.lowerBound)
            + Array(lineRows.upperBound..<(lineRows.upperBound + ring))
        for row in ringRows {
            for column in [40, 130, 215] {
                let pixel = canvas.pixel(x: column, row: row)
                #expect(close(pixel, border), "row \(row), column \(column) drew \(pixel), the border \(border)")
            }
        }
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
