//
//  DirectionalPolylineRendererTests+Shades.swift
//  OpenHikesTests
//
//  The chevrons over a coloured stretch — see ``RouteDifficultyShading``. A
//  chevron's shade is picked to contrast with the colour beneath it, and over
//  a stretch that colour is the stretch's, not the route's: the white a dark
//  blue route picks all but vanishes on a yellow stretch. Only a drawing
//  shows which one a chevron was stroked in.
//
//  Split from ``DirectionalPolylineRendererTests`` as an extension: one suite
//  per file, and the bitmap helpers are that suite's.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension DirectionalPolylineRendererTests {
    /// Byte values that separate a chevron's opaque white (1.0) and near-black
    /// (0.15) — see ``RouteChevronShade`` — from each other, from the yellow
    /// stretch and from the blue line, all four of them well clear.
    private static let opaque: UInt8 = 240
    private static let bright: UInt8 = 200
    private static let dim: UInt8 = 80

    /// Pixels drawn opaque in a colour matching `matches`, which is handed
    /// the red, green and blue bytes.
    private static func opaquePixels(in canvas: Canvas, where matches: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        guard let data = canvas.context.data else { return 0 }
        let count = canvas.context.width * canvas.context.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        return (0..<count).count { pixel in
            let base = pixel * 4
            return bytes[base + 3] > opaque && matches(bytes[base], bytes[base + 1], bytes[base + 2])
        }
    }

    private static func isWhite(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
        red > bright && green > bright && blue > bright
    }

    private static func isDark(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Bool {
        red < dim && green < dim && blue < dim
    }

    /// The directional line in dark blue, with its middle drawn across so it
    /// does not sit on the bitmap's edge — see `renderCentred` beside the
    /// border's tests — and, when `shaded`, the whole of it as one yellow
    /// stretch.
    private static func renderBlueDirectional(shaded: Bool) throws -> Canvas {
        let polyline = Self.line()
        let renderer = Self.renderer(.directional, on: polyline)
        renderer.strokeColor = .blue
        if shaded {
            renderer.setShades([
                .init(polyline: Self.line(), color: CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
            ])
        }
        let canvas = try Canvas()
        canvas.context.translateBy(x: 0, y: CGFloat(canvas.context.height / 2))
        renderer.draw(polyline.boundingMapRect, zoomScale: 1, in: canvas.context)
        return canvas
    }

    @Test("a chevron on a coloured stretch contrasts with the stretch, not the route")
    func chevronsContrastWithTheirStretch() throws {
        let plain = try Self.renderBlueDirectional(shaded: false)
        #expect(
            Self.opaquePixels(in: plain, where: Self.isWhite) > 0,
            "a dark blue line should carry white chevrons for the comparison to mean anything"
        )

        let shaded = try Self.renderBlueDirectional(shaded: true)
        #expect(Self.opaquePixels(in: shaded, where: Self.isWhite) == 0, "white chevrons were left on yellow")
        #expect(Self.opaquePixels(in: shaded, where: Self.isDark) > 0, "yellow should carry dark chevrons")
    }
}
