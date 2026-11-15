//
//  OSMCSymbolTests.swift
//  OpenHikesTests
//
//  `osmc:symbol` read the way the OpenStreetMap wiki writes it: a way colour
//  read past, a background, up to two foregrounds, and a text with its colour
//  told apart from them by their places — and left out when it is too long
//  for a sign.
//

@testable import OpenHikes
import Testing

@Suite("OSMC symbol")
struct OSMCSymbolTests {
    @Test("the Alps' red-white-red is a white sign with a red bar")
    func redWhiteRed() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_bar"))
        #expect(symbol.background == OSMCSymbol.Background(paint: .white, ground: .plain))
        #expect(symbol.foregrounds == [OSMCSymbol.Foreground(paint: .red, shape: .bar)])
        #expect(symbol.text == nil)
    }

    @Test("a text and its paint are the last two fields")
    func textAndItsPaint() throws {
        let symbol = try #require(OSMCSymbol(tag: "blue:white:blue_bar:E4:black"))
        #expect(symbol.foregrounds == [OSMCSymbol.Foreground(paint: .blue, shape: .bar)])
        #expect(symbol.text == "E4")
        #expect(symbol.textPaint == .black)
    }

    @Test("an empty foreground leaves the text where it is")
    func emptyForegroundBeforeText() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white::443:black"))
        #expect(symbol.foregrounds.isEmpty)
        #expect(symbol.text == "443")
    }

    @Test("two foregrounds are both drawn, and a shape's name keeps its underscores")
    func twoForegrounds() throws {
        let symbol = try #require(OSMCSymbol(tag: "yellow:yellow_round:green_triangle_line:black_dot"))
        #expect(symbol.background == OSMCSymbol.Background(paint: .yellow, ground: .round))
        #expect(symbol.foregrounds == [
            OSMCSymbol.Foreground(paint: .green, shape: .triangleLine),
            OSMCSymbol.Foreground(paint: .black, shape: .dot),
        ])
        #expect(symbol.text == nil)
    }

    @Test("the wiki's backgrounds with a shape read as their grounds", arguments: [
        ("blue:blue_frame", OSMCSymbol.Ground.frame),
        ("red:red_circle", .circle),
        ("green:green_round", .round),
        ("black:black", .plain),
    ])
    func grounds(tag: String, ground: OSMCSymbol.Ground) throws {
        #expect(try #require(OSMCSymbol(tag: tag)).background.ground == ground)
    }

    // swiftlint:disable american_spelling_in_copy
    @Test("OpenStreetMap's spelling of gray is read as gray")
    func osmSpellingOfGray() throws {
        #expect(try #require(OSMCSymbol(tag: "grey:grey")).background.paint == .gray)
    }
    // swiftlint:enable american_spelling_in_copy

    @Test("a shape this layer cannot draw is left out, and the rest is kept")
    func unknownShape() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_hiker:red_dot"))
        #expect(symbol.foregrounds == [OSMCSymbol.Foreground(paint: .red, shape: .dot)])
    }

    @Test("a tag with no background this layer can draw is no symbol")
    func noBackground() {
        #expect(OSMCSymbol(tag: "red") == nil)
        #expect(OSMCSymbol(tag: "red:pink") == nil)
        #expect(OSMCSymbol(tag: "red:white_star:red_bar") == nil)
        #expect(OSMCSymbol(tag: "") == nil)
    }

    @Test("one field after the foreground is a text in black when it names no shape")
    func textWithNoPaint() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_bar:E4"))
        #expect(symbol.foregrounds == [OSMCSymbol.Foreground(paint: .red, shape: .bar)])
        #expect(symbol.text == "E4")
        #expect(symbol.textPaint == .black)
    }

    @Test("three fields after the foreground are a second foreground, a text and its paint")
    func secondForegroundThenText() throws {
        let symbol = try #require(OSMCSymbol(tag: "blue:white:blue_bar:red_dot:E4:yellow"))
        #expect(symbol.foregrounds == [
            OSMCSymbol.Foreground(paint: .blue, shape: .bar),
            OSMCSymbol.Foreground(paint: .red, shape: .dot),
        ])
        #expect(symbol.text == "E4")
        #expect(symbol.textPaint == .yellow)
    }

    @Test("a text too long for a sign is left out rather than cut, and the waymark is kept")
    func longText() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_bar:VA-A44:black"))
        #expect(symbol.text == nil)
        #expect(symbol.foregrounds == [OSMCSymbol.Foreground(paint: .red, shape: .bar)])
        #expect(try #require(OSMCSymbol(tag: "red:white:red_bar:412j:black")).text == "412j")
    }
}
