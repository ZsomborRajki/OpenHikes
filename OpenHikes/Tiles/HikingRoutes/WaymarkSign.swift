//
//  WaymarkSign.swift
//  OpenHikes
//
//  The small sign the hiking-routes layer draws along a route: the route's
//  waymark, drawn from its `osmc:symbol` (``OSMCSymbol``), or — for a route
//  with a number and no symbol — the number in a box of its network's colour,
//  as Waymarked Trails draws one.
//
//  Drawn in points, around the origin, into whatever context it is handed:
//  the renderer moves and scales its map-point context so a point is a point
//  on screen. Text is set with Core Text in that context, which is flipped
//  the way UIKit's is, so its text matrix is turned over first.
//

import CoreGraphics
import CoreText
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What one route's sign says.
nonisolated enum WaymarkSign: Equatable, Sendable {
    /// A route's number, where it has no waymark: its `ref`, boxed in the
    /// colour of its network. Only for a regional route and up — a local
    /// route's number with no waymark beside it is most of what made the
    /// first prototype's map a field of boxes.
    case number(String, RouteNetwork)
    /// The waymark itself.
    case symbol(OSMCSymbol)

    /// The sign a route's tags make, or `nil` for a route with neither a
    /// waymark this layer draws nor a number worth a sign.
    init?(tags: [String: String]) {
        let network = RouteNetwork(tag: tags["network"])
        if let tag = tags["osmc:symbol"], let symbol = OSMCSymbol(tag: tag) {
            self = .symbol(symbol)
        } else if network >= .regional, let ref = tags["ref"]?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            self = .number(String(ref.prefix(OSMCSymbol.maximumTextLength)), network)
        } else {
            return nil
        }
    }

    /// The sign's height in points, and its width for one with no text: the
    /// size Waymarked Trails' shields stand on screen.
    static let side: CGFloat = 10
    private static let textPadding: CGFloat = 2
    private static let fontSize: CGFloat = 7
    private static let outlineWidth: CGFloat = 0.5
    private static let numberCornerRadius: CGFloat = 2

    /// The sign's size, in points: square, or as wide as its text needs.
    var size: CGSize {
        guard let text else { return CGSize(width: Self.side, height: Self.side) }
        let width = CTLineGetTypographicBounds(Self.line(text, paint: .black), nil, nil, nil)
        return CGSize(width: max(Self.side, CGFloat(width) + Self.textPadding * 2), height: Self.side)
    }

    private var text: String? {
        switch self {
        case .symbol(let symbol): symbol.text
        case .number(let number, _): number
        }
    }

    /// Draws the sign centred on the origin of `context`, one unit a point.
    func draw(in context: CGContext) {
        let measured = size
        let frame = CGRect(
            x: -measured.width / 2,
            y: -measured.height / 2,
            width: measured.width,
            height: measured.height
        )
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [])
        switch self {
        case .symbol(let symbol):
            Self.drawBackground(symbol.background, in: frame, context: context)
            for foreground in symbol.foregrounds {
                WaymarkShapes.draw(foreground.shape, paint: foreground.paint, in: frame, context: context)
            }
            if let words = symbol.text {
                Self.draw(words, paint: symbol.textPaint, in: frame, context: context)
            }
        case let .number(number, network):
            let box = CGPath(
                roundedRect: frame,
                cornerWidth: Self.numberCornerRadius,
                cornerHeight: Self.numberCornerRadius,
                transform: nil
            )
            context.addPath(box)
            context.setFillColor(HikingRoutesRenderer.color(of: network))
            context.fillPath()
            Self.draw(number, paint: .white, in: frame, context: context)
        }
        context.addRect(frame.insetBy(dx: Self.outlineWidth / 2, dy: Self.outlineWidth / 2))
        context.setLineWidth(Self.outlineWidth)
        context.setStrokeColor(Self.outlineColor)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - The parts

nonisolated private extension WaymarkSign {
    static let outlineColor = CGColor(gray: 0, alpha: outlineAlpha)
    static let outlineAlpha: CGFloat = 0.45

    static func drawBackground(_ background: OSMCSymbol.Background, in frame: CGRect, context: CGContext) {
        let paint = WaymarkShapes.color(of: background.paint)
        let white = WaymarkShapes.color(of: .white)
        let disc = WaymarkShapes.square(in: frame).insetBy(dx: frame.height / 8, dy: frame.height / 8)
        switch background.ground {
        case .plain:
            context.setFillColor(paint)
            context.fill(frame)
        case .frame:
            context.setFillColor(white)
            context.fill(frame)
            context.setStrokeColor(paint)
            context.setLineWidth(frame.height / 6)
            context.stroke(frame.insetBy(dx: frame.height / 12, dy: frame.height / 12))
        case .circle:
            context.setFillColor(white)
            context.fill(frame)
            context.setStrokeColor(paint)
            context.setLineWidth(frame.height / 8)
            context.strokeEllipse(in: disc)
        case .round:
            context.setFillColor(white)
            context.fill(frame)
            context.setFillColor(paint)
            context.fillEllipse(in: disc)
        }
    }

    static func line(_ text: String, paint: OSMCSymbol.Paint) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): WaymarkShapes.color(of: paint),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// `text` centred in `frame`, in a context whose y runs down.
    static func draw(_ text: String, paint: OSMCSymbol.Paint, in frame: CGRect, context: CGContext) {
        let line = line(text, paint: paint)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: frame.midX - width / 2, y: frame.midY + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
