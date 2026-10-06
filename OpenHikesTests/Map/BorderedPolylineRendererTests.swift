//
//  BorderedPolylineRendererTests.swift
//  OpenHikesTests
//
//  The outline round the trail being drawn and a recording's line, drawn into
//  a bitmap with MapKit's own stroke as the reference — see
//  `DirectionalPolylineRendererTests+Border.swift`, whose canvas and pixel
//  helpers these borrow, for what a bitmap can and cannot show about it.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import Testing

@Suite("Bordered polyline rendering")
struct BorderedPolylineRendererTests {
    private typealias Canvas = DirectionalPolylineRendererTests.Canvas

    private static let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    private static func renderer(
        on polyline: MKPolyline,
        border: CGColor?,
        dashes: [Double] = [],
        alpha: CGFloat = 1
    ) -> BorderedPolylineRenderer {
        let renderer = BorderedPolylineRenderer(polyline: polyline)
        renderer.lineWidth = 6
        renderer.lineJoin = .round
        renderer.lineCap = .round
        renderer.strokeColor = .red.withAlphaComponent(alpha)
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = dashes.isEmpty ? nil : dashes.map { NSNumber(value: $0) }
        renderer.borderColor = border
        return renderer
    }

    /// Across the middle of the canvas, for the reason the directional
    /// suite's own `renderCentred` gives.
    private static func renderCentred(
        _ renderer: BorderedPolylineRenderer,
        of polyline: MKPolyline,
        zoomScale: MKZoomScale = 1
    ) throws -> Canvas {
        let canvas = try Canvas()
        canvas.context.translateBy(x: 0, y: CGFloat(canvas.context.height / 2))
        renderer.draw(polyline.boundingMapRect, zoomScale: zoomScale, in: canvas.context)
        return canvas
    }

    @Test("no border, or a clear one, draws exactly the plain line")
    func noBorderDrawsThePlainLine() throws {
        let polyline = DirectionalPolylineRendererTests.line()
        let plain = try Self.renderCentred(Self.renderer(on: polyline, border: nil), of: polyline)
        let clear = try Self.renderCentred(
            Self.renderer(on: polyline, border: CGColor(red: 0, green: 0, blue: 0, alpha: 0)),
            of: polyline
        )
        #expect(plain.inkedPixels > 0)
        #expect(clear.inkedPixels == plain.inkedPixels)
    }

    /// A 6 pt line carries a 2 pt border each side, so the band grows from 6
    /// rows to 10, a row either way for anti-aliasing.
    @Test("the border reaches past the line by the border's width on each side")
    func borderWidensTheBand() throws {
        let polyline = DirectionalPolylineRendererTests.line()
        let line = try Self.renderCentred(Self.renderer(on: polyline, border: nil), of: polyline)
        let bordered = try Self.renderCentred(Self.renderer(on: polyline, border: Self.black), of: polyline)

        let lineRows = line.inkedRows(inColumn: 100)
        let borderedRows = bordered.inkedRows(inColumn: 100)
        #expect(lineRows > 0)
        #expect((3...5).contains(borderedRows - lineRows), "\(lineRows) rows grew to \(borderedRows)")
    }

    /// The line's own dashes, not a route pattern's: the maker's legs and the
    /// recording dash by what their state means.
    @Test("a dashed line's border follows its own dashes and leaves the gaps open")
    func dashedBorderFollowsTheLinesDashes() throws {
        let polyline = DirectionalPolylineRendererTests.line()
        // Gaps wide enough to survive the round caps a 6 pt line and its
        // 10 pt border put on each dash.
        let dashes = [10.0, 20.0]
        let lineOnly = try Self.renderCentred(
            Self.renderer(on: polyline, border: nil, dashes: dashes),
            of: polyline,
            zoomScale: 0.5
        )
        let bordered = try Self.renderCentred(
            Self.renderer(on: polyline, border: Self.black, dashes: dashes),
            of: polyline,
            zoomScale: 0.5
        )

        let row = try #require(lineOnly.mostInkedRow)
        let width = lineOnly.context.width
        let lineColumns = (0..<width).filter { lineOnly.isInked(x: $0, row: row) }
        let borderedColumns = (0..<width).filter { bordered.isInked(x: $0, row: row) }
        #expect(lineOnly.inkedRuns(inRow: row).count > 1, "precondition: the line is dashed")
        #expect(lineColumns.allSatisfy { bordered.isInked(x: $0, row: row) })
        #expect(borderedColumns.count > lineColumns.count, "the outline reached no further than the dashes")
        #expect(borderedColumns.count < width, "the outline closed the gaps between dashes")
    }

    /// The recording's red is translucent. The border is a ring round it,
    /// so the middle of the line is the line's own colour at its own alpha,
    /// not red over black.
    @Test("a translucent line shows no border through it")
    func translucentLineIsNotDarkened() throws {
        let polyline = DirectionalPolylineRendererTests.line()
        let plain = try Self.renderCentred(Self.renderer(on: polyline, border: nil, alpha: 0.5), of: polyline)
        let bordered = try Self.renderCentred(
            Self.renderer(on: polyline, border: Self.black, alpha: 0.5),
            of: polyline
        )
        let row = try #require(plain.mostInkedRow)
        #expect(bordered.pixel(x: 100, row: row) == plain.pixel(x: 100, row: row))
    }
}
