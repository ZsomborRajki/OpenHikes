//
//  OSMCSymbol.swift
//  OpenHikes
//
//  The waymark painted on the trees and rocks along a route, as OpenStreetMap
//  describes it in a route's `osmc:symbol` tag.
//
//  The tag is `waycolour:background[:foreground][:foreground2][:text:textcolour]`
//  — see the OpenStreetMap wiki's *Key:osmc:symbol*. `red:white:red_bar` is the
//  Alps' red-white-red; `blue:white:blue_bar:E4:black` adds the route's number.
//  The way colour is the line's, which the layer draws by network instead, so
//  it is read past. A background is a colour, or a colour and a shape —
//  `white_circle`, `blue_frame`, `yellow_round`; a foreground is a colour and a
//  shape, `red_bar`, `blue_dot`, `black_triangle_line`.
//
//  **Only what this file can draw is kept.** A shape it does not know — the
//  wiki lists hikers, shells, wolf hooks and more — is dropped rather than
//  guessed at, and a tag that names no background at all is no symbol. The
//  text and its colour are told from a third foreground by their places: two
//  fields at the end, of which the last is a colour and the first is not a
//  foreground.
//

import Foundation

/// One `osmc:symbol`, as far as the layer draws it.
nonisolated struct OSMCSymbol: Equatable, Sendable {
    /// The colours the wiki lists, `grey` read as `gray`.
    nonisolated enum Paint: String, Sendable {
        case black = "black"
        case blue = "blue"
        case brown = "brown"
        case gray = "gray"
        case green = "green"
        case orange = "orange"
        case purple = "purple"
        case red = "red"
        case white = "white"
        case yellow = "yellow"

        init?(tag: Substring) {
            // OpenStreetMap's spelling, which taggers use as often as ours.
            // swiftlint:disable:next american_spelling_in_copy
            self.init(rawValue: tag == "grey" ? "gray" : String(tag))
        }
    }

    /// How the background fills the sign.
    nonisolated enum Ground: String, Sendable {
        /// A ring of the colour on white.
        case circle = "circle"
        /// A border of the colour around white.
        case frame = "frame"
        /// The whole sign in the colour.
        case plain = ""
        /// A disc of the colour on white.
        case round = "round"
    }

    /// The marks the layer draws, by the wiki's names.
    nonisolated enum Shape: String, Sendable {
        case arch = "arch"
        case backslash = "backslash"
        case bar = "bar"
        case circle = "circle"
        case corner = "corner"
        case cross = "cross"
        case diamond = "diamond"
        case diamondLeft = "diamond_left"
        case diamondLine = "diamond_line"
        case diamondRight = "diamond_right"
        case dot = "dot"
        case fork = "fork"
        case lShape = "L"
        case lower = "lower"
        case pointer = "pointer"
        case rectangle = "rectangle"
        case rectangleLine = "rectangle_line"
        case right = "right"
        case slash = "slash"
        case stripe = "stripe"
        case triangle = "triangle"
        case triangleLine = "triangle_line"
        case triangleTurned = "triangle_turned"
        case turnedT = "turned_T"
        case xShape = "x"
    }

    nonisolated struct Background: Equatable, Sendable {
        var paint: Paint
        var ground: Ground
    }

    nonisolated struct Foreground: Equatable, Sendable {
        var paint: Paint
        var shape: Shape
    }

    /// The longest text a sign carries; past it the text is cut, as a sign
    /// on a tree is.
    static let maximumTextLength = 6

    var background: Background
    var foregrounds: [Foreground]
    var text: String?
    var textPaint: Paint

    /// The symbol a tag describes, or `nil` when it names no background this
    /// file can draw.
    init?(tag: String) {
        let fields = tag.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces)[...] }
        guard fields.count >= 2, let ground = Self.background(fields[1]) else { return nil }
        background = ground
        var rest = Array(fields.dropFirst(2))
        text = nil
        textPaint = .black
        if rest.count >= 2, let paint = Paint(tag: rest[rest.count - 1]), Self.foreground(rest[rest.count - 2]) == nil {
            let words = rest[rest.count - 2]
            text = words.isEmpty ? nil : String(words.prefix(Self.maximumTextLength))
            textPaint = paint
            rest.removeLast(2)
        }
        foregrounds = rest.compactMap(Self.foreground)
    }

    private static func background(_ field: Substring) -> Background? {
        let parts = field.split(separator: "_", maxSplits: 1)
        guard let first = parts.first, let paint = Paint(tag: first) else { return nil }
        guard parts.count == 2 else { return Background(paint: paint, ground: .plain) }
        guard let ground = Ground(rawValue: String(parts[1])), ground != .plain else { return nil }
        return Background(paint: paint, ground: ground)
    }

    private static func foreground(_ field: Substring) -> Foreground? {
        let parts = field.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let paint = Paint(tag: parts[0]),
              let shape = Shape(rawValue: String(parts[1]))
        else { return nil }
        return Foreground(paint: paint, shape: shape)
    }
}
