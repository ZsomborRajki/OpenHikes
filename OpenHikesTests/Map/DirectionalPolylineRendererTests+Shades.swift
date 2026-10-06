//
//  DirectionalPolylineRendererTests+Shades.swift
//  OpenHikesTests
//
//  The coloured stretches — see ``RouteShading`` — as drawn. A chevron's
//  shade is picked to contrast with the colour beneath it, and over a stretch
//  that colour is the stretch's, not the route's: the white a dark blue route
//  picks all but vanishes on a yellow stretch. And where two stretches meet,
//  the colour blends from one into the other (``RouteShadeBlend``) without
//  the line's alpha doubling where the blend is laid over them. Only a
//  drawing shows either.
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

    /// A pixel's premultiplied bytes.
    private struct Pixel {
        let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    }

    private static func pixel(in canvas: Canvas, x: Int, y: Int) -> Pixel {
        guard let data = canvas.context.data else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: canvas.context.width * canvas.context.height * 4)
        let base = (y * canvas.context.width + x) * 4
        return Pixel(red: bytes[base], green: bytes[base + 1], blue: bytes[base + 2], alpha: bytes[base + 3])
    }

    /// The meeting line's figures: its length, the stretches' meeting point
    /// half way, the margin shown either side of it, and its point spacing.
    private static let meetingLatitude = 47.6
    private static let meetingLongitude = 12.9
    private static let meetingStart = MKMapPoint(
        CLLocationCoordinate2D(latitude: meetingLatitude, longitude: meetingLongitude)
    )
    private static let meetingLength = 400.0
    private static let meetingMargin = 20.0
    private static let meetingSpacing = 10.0

    /// Map points along the meeting line, from and to metres along it.
    private static func meetingPoints(_ from: Double, _ to: Double) -> [MKMapPoint] {
        let perMeter = MKMapPointsPerMeterAtLatitude(meetingLatitude)
        return stride(from: from, through: to, by: meetingSpacing).map { meters in
            MKMapPoint(x: meetingStart.x + meters * perMeter, y: meetingStart.y)
        }
    }

    private static func stretch(_ from: Double, _ to: Double, _ color: CGColor) -> DirectionalPolylineRenderer.Shade {
        let points = meetingPoints(from, to)
        return .init(polyline: MKPolyline(points: points, count: points.count), color: color)
    }

    /// Draws `polyline` solid with `shades` over it, in the canvas
    /// ``renderMeeting(alpha:)`` frames.
    private static func render(_ polyline: MKPolyline, shades: [DirectionalPolylineRenderer.Shade]) throws -> Canvas {
        let renderer = Self.renderer(.solid, on: polyline)
        renderer.setShades(shades)
        let canvas = try Canvas()
        let perMeter = MKMapPointsPerMeterAtLatitude(meetingLatitude)
        let shown = (meetingLength + meetingMargin * 2) * perMeter
        let zoom = CGFloat(Double(canvas.context.width) / shown)
        let rect = MKMapRect(
            x: meetingStart.x - meetingMargin * perMeter,
            y: meetingStart.y - shown / 2,
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

    /// A solid green line east along a parallel, drawn red over its first
    /// half and blue over its second, at `alpha`, centred in a canvas just
    /// wider than it — so the canvas's middle row is the line and its middle
    /// column the place the stretches meet.
    private static func renderMeeting(alpha: CGFloat) throws -> Canvas {
        let whole = meetingPoints(0, meetingLength)
        let polyline = MKPolyline(points: whole, count: whole.count)
        let renderer = Self.renderer(.solid, on: polyline)
        renderer.strokeColor = UIColor.green.withAlphaComponent(alpha)
        let half = meetingLength / 2
        renderer.setShades([
            stretch(0, half, CGColor(red: 1, green: 0, blue: 0, alpha: alpha)),
            stretch(half, meetingLength, CGColor(red: 0, green: 0, blue: 1, alpha: alpha)),
        ])
        let canvas = try Canvas()
        let perMeter = MKMapPointsPerMeterAtLatitude(meetingLatitude)
        let shown = (meetingLength + meetingMargin * 2) * perMeter
        let zoom = CGFloat(Double(canvas.context.width) / shown)
        let rect = MKMapRect(
            x: meetingStart.x - meetingMargin * perMeter,
            y: meetingStart.y - shown / 2,
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

    /// An out-and-back trail draws its return leg over its outward one, and
    /// the outward leg's blends belong underneath it like the rest of that
    /// leg — drawn after every stretch, they showed through as dark patches
    /// on the leg coming back.
    @Test("a leg that doubles back covers the blends on the leg beneath it")
    func returnLegCoversTheOutwardBlend() throws {
        let out = Self.meetingPoints(0, Self.meetingLength)
        let back = Array(out.reversed())
        let whole = out + back.dropFirst()
        let half = Self.meetingLength / 2
        let returning = MKPolyline(points: back, count: back.count)
        let canvas = try Self.render(
            MKPolyline(points: whole, count: whole.count),
            shades: [
                Self.stretch(0, half, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                Self.stretch(half, Self.meetingLength, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                .init(polyline: returning, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            ]
        )

        let middle = Self.pixel(in: canvas, x: canvas.context.width / 2, y: canvas.context.height / 2)
        #expect(
            middle.green > Self.bright && middle.red < Self.dim && middle.blue < Self.dim,
            "the returning green leg should be all that shows where the outward leg blended red into blue"
        )
    }

    /// The same out-and-back at the line's alpha: the leg coming back is
    /// laid over the one going out, and has to replace it rather than add
    /// its alpha to it.
    @Test("a translucent leg that doubles back is no more opaque than the line")
    func translucentReturnLegKeepsTheLinesAlpha() throws {
        let out = Self.meetingPoints(0, Self.meetingLength)
        let back = Array(out.reversed())
        let whole = out + back.dropFirst()
        let going = MKPolyline(points: out, count: out.count)
        let returning = MKPolyline(points: back, count: back.count)
        let canvas = try Self.render(
            MKPolyline(points: whole, count: whole.count),
            shades: [
                .init(polyline: going, color: CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)),
                .init(polyline: returning, color: CGColor(red: 0, green: 0, blue: 1, alpha: 0.5)),
            ]
        )

        let middle = Self.pixel(in: canvas, x: canvas.context.width / 2, y: canvas.context.height / 2)
        #expect(abs(Int(middle.alpha) - 128) <= 8, "the two legs' alphas were stacked")
        #expect(middle.blue > middle.red, "the leg coming back should be the one on top")
    }

    @Test("where two stretches meet the colour blends from one into the other")
    func meetingStretchesBlend() throws {
        let canvas = try Self.renderMeeting(alpha: 1)
        let row = canvas.context.height / 2
        let red = Self.pixel(in: canvas, x: canvas.context.width * 2 / 7, y: row)
        let middle = Self.pixel(in: canvas, x: canvas.context.width / 2, y: row)
        let blue = Self.pixel(in: canvas, x: canvas.context.width * 5 / 7, y: row)

        #expect(red.red > Self.bright && red.blue < Self.dim, "the first stretch is red away from the blend")
        #expect(blue.blue > Self.bright && blue.red < Self.dim, "the second is blue away from the blend")
        #expect(
            middle.red > Self.dim && middle.blue > Self.dim && middle.green < Self.dim,
            "the meeting point should be a mix of the two, and none of the line under them"
        )
    }

    /// The blend is laid over the ends of the stretches it joins; drawn
    /// each at the line's alpha, the overlap would come out twice as opaque.
    @Test("a translucent line is no more opaque where its stretches blend")
    func blendKeepsTheLinesAlpha() throws {
        let canvas = try Self.renderMeeting(alpha: 0.5)
        let row = canvas.context.height / 2
        let core = Self.pixel(in: canvas, x: canvas.context.width * 2 / 7, y: row)
        let middle = Self.pixel(in: canvas, x: canvas.context.width / 2, y: row)

        #expect(abs(Int(core.alpha) - 128) <= 8)
        #expect(abs(Int(middle.alpha) - Int(core.alpha)) <= 4)
    }
}
