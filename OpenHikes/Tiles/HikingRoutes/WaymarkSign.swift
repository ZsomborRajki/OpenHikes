//
//  WaymarkSign.swift
//  OpenHikes
//
//  The small sign the hiking-routes layer draws along a route: the route's
//  waymark, drawn from its `osmc:symbol` (``OSMCSymbol``), or — for a route
//  with no waymark this layer draws — its number or its initials in a white
//  box. Either is framed in the colour of the route's network, as Waymarked
//  Trails frames one.
//
//  Drawn in tile pixels, around the origin, into whatever context it is
//  handed: the renderer moves and scales its map-point context so that one
//  unit is one pixel of a map tile (see ``HikingRoutesStyle``). Text is set
//  with Core Text in that context, which is flipped the way UIKit's is, so
//  its text matrix is turned over first.
//

import CoreGraphics
import CoreText
import Foundation

/// What one route's sign shows.
nonisolated struct WaymarkSign: Hashable, Sendable {
    nonisolated enum Content: Hashable, Sendable {
        /// The route's number, or what stands in for one: see
        /// ``WaymarkSign/reference(from:)``.
        case reference(String)
        /// The waymark itself.
        case symbol(OSMCSymbol)
    }

    let content: Content
    /// The network whose colour frames the sign, and which decides the zooms
    /// it is shown at. Never ``RouteNetwork/other``: a route outside
    /// OpenStreetMap's scheme is a local one here, so two routes with the
    /// same waymark share one sign whichever of the two they are.
    let network: RouteNetwork

    /// The sign a route's tags make, or `nil` for a route with no waymark
    /// this layer draws, no number and no name.
    init?(tags: [String: String]) {
        network = max(RouteNetwork(tag: tags["network"]), .local)
        if let tag = tags["osmc:symbol"], let symbol = OSMCSymbol(tag: tag) {
            content = .symbol(symbol)
        } else if let reference = Self.reference(from: tags) {
            content = .reference(reference)
        } else {
            return nil
        }
    }

    /// What a route with no waymark is called on its sign: its `ref` without
    /// the spaces, or — with no `ref` — its name when that is short enough,
    /// the capitals and digits of a longer one, and the start of a name with
    /// fewer than two of those. Cut to ``maximumReferenceLength``.
    static func reference(from tags: [String: String]) -> String? {
        if let ref = tags["ref"]?.filter({ !$0.isWhitespace }), !ref.isEmpty {
            return String(ref.prefix(maximumReferenceLength))
        }
        guard let name = tags["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        guard name.count > maximumReferenceLength else { return name }
        let initials = name.filter { $0.isUppercase || $0.isNumber }
        guard initials.count > 1 else {
            return String(name.filter { !$0.isWhitespace }.prefix(maximumReferenceLength))
        }
        return String(initials.prefix(maximumReferenceLength))
    }

    static let maximumReferenceLength = 5

    /// The sign's height in tile pixels, and its width for one with no text.
    static let side: CGFloat = 16
    /// The frame's width.
    static let frameWidth: CGFloat = 1.2
    private static let textPadding: CGFloat = 2.5
    private static let fontSize: CGFloat = 7.5

    /// The sign's size, in tile pixels: square, or as wide as its text needs.
    var size: CGSize {
        guard let text else { return CGSize(width: Self.side, height: Self.side) }
        let width = CGFloat(CTLineGetTypographicBounds(Self.line(text, paint: .black), nil, nil, nil))
        let needed = (width + 2 * (Self.textPadding + Self.frameWidth)).rounded(.up)
        return CGSize(width: max(Self.side, needed), height: Self.side)
    }

    private var text: String? {
        switch content {
        case .symbol(let symbol): symbol.text
        case .reference(let reference): reference
        }
    }

    /// Draws the sign centred on the origin of `context`, one unit a tile
    /// pixel.
    func draw(in context: CGContext) {
        let measured = size
        let frame = CGRect(
            x: -measured.width / 2,
            y: -measured.height / 2,
            width: measured.width,
            height: measured.height
        )
        let inside = frame.insetBy(dx: Self.frameWidth, dy: Self.frameWidth)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [])
        switch content {
        case .symbol(let symbol):
            Self.drawBackground(symbol.background, in: frame, context: context)
            for foreground in symbol.foregrounds {
                WaymarkShapes.draw(foreground.shape, paint: foreground.paint, in: inside, context: context)
            }
            if let words = symbol.text {
                Self.draw(words, paint: symbol.textPaint, in: frame, context: context)
            }
        case .reference(let reference):
            context.setFillColor(WaymarkShapes.color(of: .white))
            context.fill(frame)
            Self.draw(reference, paint: .black, in: frame, context: context)
        }
        context.addRect(frame.insetBy(dx: Self.frameWidth / 2, dy: Self.frameWidth / 2))
        context.setLineWidth(Self.frameWidth)
        context.setStrokeColor(HikingRoutesStyle.signFrame(of: network))
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - The parts

nonisolated private extension WaymarkSign {
    static func drawBackground(_ background: OSMCSymbol.Background, in frame: CGRect, context: CGContext) {
        let paint = WaymarkShapes.color(of: background.paint)
        // A ring, a border or a disc stands on white, or on black where it
        // is white itself.
        let field = WaymarkShapes.color(of: background.paint == .white ? .black : .white)
        let disc = WaymarkShapes.square(in: frame).insetBy(dx: frame.height / 8, dy: frame.height / 8)
        switch background.ground {
        case .plain:
            context.setFillColor(paint)
            context.fill(frame)
        case .frame:
            context.setFillColor(field)
            context.fill(frame)
            context.setStrokeColor(paint)
            context.setLineWidth(frame.height / 8)
            context.stroke(frame.insetBy(dx: frame.height / 8, dy: frame.height / 8))
        case .circle:
            context.setFillColor(field)
            context.fill(frame)
            context.setStrokeColor(paint)
            context.setLineWidth(frame.height / 8)
            context.strokeEllipse(in: disc)
        case .round:
            context.setFillColor(field)
            context.fill(frame)
            context.setFillColor(paint)
            context.fillEllipse(in: disc)
        }
    }

    /// The system's bold face, condensed where the system has one: a sign's
    /// number is four or five characters in sixteen pixels.
    static func font() -> CTFont {
        let bold = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        return CTFontCreateCopyWithSymbolicTraits(bold, fontSize, nil, .traitCondensed, .traitCondensed) ?? bold
    }

    static func line(_ text: String, paint: OSMCSymbol.Paint) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(),
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
        let capHeight = CTFontGetCapHeight(font())
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: frame.midX - width / 2, y: frame.midY + capHeight / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
