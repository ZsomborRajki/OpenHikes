//
//  OSMCSymbolTests.swift
//  OpenHikesTests
//
//  `osmc:symbol` read the way the OpenStreetMap wiki writes it: a way colour
//  read past, a background, up to two foregrounds, and a text with its colour
//  told apart from them by their places.
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

    @Test("a long text is cut, as a sign on a tree is")
    func longText() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_bar:Maximiliansweg:black"))
        #expect(symbol.text == "Maximi")
    }
}
