//
//  DirectionalPolylineRendererTests+Border.swift
//  OpenHikesTests
//
//  The border rings a stroke MapKit draws: the line on top of it is
//  `MKPolylineRenderer`'s, and the border — a wider copy of it with the line
//  cleared back out — has to fit that line in width and, on a dashed route,
//  dash for dash. Only a drawing shows whether it does, so
//  these draw both into a bitmap and compare the ink, with MapKit's stroke as
//  the reference.
//
//  What a bitmap cannot show is the renderer's `contentScaleFactor`, which is
//  one off a map and the screen's scale on one — and MapKit widens its line by
//  it. A border that ignored it passed every test here and was invisible on a
//  device, hidden under a line three times wider than it assumed. That half is
//  checked by eye, on a simulator.
//
//  Split from ``DirectionalPolylineRendererTests`` as an extension: one suite
//  per file, and the bitmap helpers are that suite's.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import Testing

extension DirectionalPolylineRendererTests {
    private static let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    /// The line drawn across the middle of the canvas rather than along its
    /// edge: a line of constant latitude has a bounding rect of zero height,
    /// so it sits on the renderer's y = 0 and half of every stroke would fall
    /// off the bitmap.
    private static func renderCentred(
        _ renderer: DirectionalPolylineRenderer,
        of polyline: MKPolyline,
        zoomScale: MKZoomScale = 1
    ) throws -> Canvas {
        let canvas = try Canvas()
        canvas.context.translateBy(x: 0, y: CGFloat(canvas.context.height / 2))
        renderer.draw(polyline.boundingMapRect, zoomScale: zoomScale, in: canvas.context)
        return canvas
    }

    /// The renderer as the map coordinator styles it: the pattern's own dashes
    /// and cap, which the coordinator sets and ``renderer(_:on:)`` does not.
    private static func styled(
        _ pattern: RouteLinePattern,
        on polyline: MKPolyline,
        border: CGColor?
    ) -> DirectionalPolylineRenderer {
        let renderer = renderer(pattern, on: polyline)
        let dashes = pattern.dashLengths(forWidth: Double(renderer.lineWidth))
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
        renderer.lineCap = pattern.lineCap
        renderer.lineJoin = .round
        renderer.borderColor = border
        return renderer
    }

    @Test("a transparent border draws exactly what no border draws")
    func transparentBorderDrawsNothing() throws {
        let polyline = Self.line()
        let none = try Self.renderCentred(Self.styled(.directional, on: polyline, border: nil), of: polyline)
        let clear = try Self.renderCentred(
            Self.styled(.directional, on: polyline, border: CGColor(red: 1, green: 1, blue: 1, alpha: 0)),
            of: polyline
        )
        #expect(clear.inkedPixels == none.inkedPixels)
    }

    /// A 6 pt line carries a 2 pt border each side, so the band across it
    /// grows from 6 rows to 10. Measured against MapKit's own stroke rather
    /// than a literal, so a MapKit that scaled its width differently from the
    /// border would show up as the difference moving, not as a number
    /// somebody has to re-derive. A row either way for anti-aliasing.
    @Test("the border reaches past the line by the border's width on each side")
    func borderWidensTheBand() throws {
        let polyline = Self.line()
        let line = try Self.renderCentred(Self.styled(.solid, on: polyline, border: nil), of: polyline)
        let bordered = try Self.renderCentred(Self.styled(.solid, on: polyline, border: Self.red), of: polyline)

        let lineRows = line.inkedRows(inColumn: 100)
        let borderedRows = bordered.inkedRows(inColumn: 100)
        #expect(lineRows > 0, "the line itself has to draw for the comparison to mean anything")
        #expect((3...5).contains(borderedRows - lineRows), "\(lineRows) rows grew to \(borderedRows)")
    }

    /// Drawn at half zoom so the dash lengths go through the same map-point
    /// scaling MapKit gives its own. Along the line's centre the outline shows
    /// only where it passes a dash's ends — it is a ring round each dash, and
    /// the dash covers its inside — so the bordered line has to ink every
    /// column the dash does, a few more at each end, and still leave gaps.
    @Test("every dash of a dashed line is outlined past its ends, and the gaps stay open")
    func dashedBorderFollowsEachDash() throws {
        let polyline = Self.line()
        let lineOnly = try Self.renderCentred(
            Self.styled(.dashed, on: polyline, border: nil),
            of: polyline,
            zoomScale: 0.5
        )
        let bordered = try Self.renderCentred(
            Self.styled(.dashed, on: polyline, border: Self.red),
            of: polyline,
            zoomScale: 0.5
        )

        let row = try #require(lineOnly.mostInkedRow)
        let width = lineOnly.context.width
        let lineColumns = (0..<width).filter { lineOnly.isInked(x: $0, row: row) }
        let borderedColumns = (0..<width).filter { bordered.isInked(x: $0, row: row) }
        #expect(!lineColumns.isEmpty)
        #expect(lineColumns.allSatisfy { bordered.isInked(x: $0, row: row) })
        #expect(borderedColumns.count > lineColumns.count, "the outline reached no further than the dashes")
        #expect(borderedColumns.count < width, "the outline closed the gaps between dashes")
    }

    /// The border's dashes are MapKit's too, lengthened and started early, so
    /// the one thing a bitmap can check that the count above cannot is that
    /// they are started early by the right amount: the outline has to reach
    /// the same distance past both ends of every dash — 2 pt at half zoom,
    /// four pixels — not all of it past one end.
    @Test("each dash's outline reaches the same distance past both of its ends")
    func dashOutlineIsCentred() throws {
        let polyline = Self.line()
        let lineOnly = try Self.renderCentred(
            Self.styled(.dashed, on: polyline, border: nil),
            of: polyline,
            zoomScale: 0.5
        )
        let bordered = try Self.renderCentred(
            Self.styled(.dashed, on: polyline, border: Self.red),
            of: polyline,
            zoomScale: 0.5
        )

        let row = try #require(lineOnly.mostInkedRow)
        let dashes = lineOnly.inkedRuns(inRow: row)
        let outlines = bordered.inkedRuns(inRow: row)
        // Runs touching the canvas edge are cut off by it, not by a dash end.
        let width = lineOnly.context.width
        let inner = dashes.filter { $0.lowerBound > 8 && $0.upperBound < width - 8 }
        #expect(inner.count >= 2, "the canvas has to hold whole dashes for this to mean anything")
        for dash in inner {
            let outline = try #require(outlines.first { $0.overlaps(dash) })
            let before = dash.lowerBound - outline.lowerBound
            let after = outline.upperBound - dash.upperBound
            #expect((3...5).contains(before) && (3...5).contains(after), "\(dash) outlined as \(outline)")
        }
    }

    /// The border is a wider line with the line cleared back out of it, so
    /// what shows through a translucent line is the map, exactly as with no
    /// border, and not the border colour.
    @Test("a translucent line shows no border through it")
    func translucentLineIsNotTinted() throws {
        let polyline = Self.line()
        let lineOnly = Self.styled(.solid, on: polyline, border: nil)
        let bordered = Self.styled(.solid, on: polyline, border: Self.red)
        for renderer in [lineOnly, bordered] {
            renderer.strokeColor = UIColor.blue.withAlphaComponent(0.5)
        }
        let plain = try Self.renderCentred(lineOnly, of: polyline)
        let outlined = try Self.renderCentred(bordered, of: polyline)

        let row = try #require(plain.mostInkedRow)
        #expect(outlined.pixel(x: 100, row: row) == plain.pixel(x: 100, row: row))
        #expect(outlined.inkedRows(inColumn: 100) > plain.inkedRows(inColumn: 100), "the ring still has to draw")
    }

    @Test("a line with no colour at all leaves only the ring")
    func colourlessLineLeavesARing() throws {
        let polyline = Self.line()
        let reference = try Self.renderCentred(Self.styled(.solid, on: polyline, border: nil), of: polyline)
        let row = try #require(reference.mostInkedRow)
        let renderer = Self.styled(.solid, on: polyline, border: Self.red)
        renderer.strokeColor = .clear
        let canvas = try Self.renderCentred(renderer, of: polyline)

        #expect(!canvas.isInked(x: 100, row: row), "the middle of the line is cleared")
        #expect(canvas.inkedRows(inColumn: 100) > 0, "and the ring round it is not")
    }

    @Test("chevrons with no line under them are outlined too")
    func arrowheadsAreOutlined() throws {
        let polyline = Self.line()
        let plain = try Self.renderCentred(Self.styled(.arrowheads, on: polyline, border: nil), of: polyline)
        let outlined = try Self.renderCentred(Self.styled(.arrowheads, on: polyline, border: Self.red), of: polyline)
        #expect(outlined.inkedPixels > plain.inkedPixels)
    }
}

extension DirectionalPolylineRendererTests.Canvas {
    /// Whether the pixel at column `x` of memory row `row` has any ink.
    func isInked(x: Int, row: Int) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        return bytes[row * context.bytesPerRow + x * 4 + 3] != 0
    }

    func inkedRows(inColumn x: Int) -> Int {
        (0..<context.height).count { isInked(x: x, row: $0) }
    }

    /// The RGBA bytes of one pixel, premultiplied as the bitmap stores them.
    func pixel(x: Int, row: Int) -> [UInt8] {
        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        let start = row * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + start, count: 4))
    }

    /// Each unbroken stretch of inked pixels along memory row `row`.
    func inkedRuns(inRow row: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0...context.width {
            let inked = x < context.width && isInked(x: x, row: row)
            if inked, start == nil { start = x }
            if !inked, let begun = start {
                runs.append(begun..<x)
                start = nil
            }
        }
        return runs
    }

    /// The row through the middle of a horizontal line: the one with the most
    /// ink in it. `nil` on a blank canvas.
    var mostInkedRow: Int? {
        let counts = (0..<context.height).map { row in
            (0..<context.width).count { isInked(x: $0, row: row) }
        }
        guard let most = counts.max(), most > 0 else { return nil }
        return counts.firstIndex(of: most)
    }
}
