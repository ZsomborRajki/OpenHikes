//
//  RouteLinePatternTests.swift
//  OpenHikesTests
//
//  "Route line pattern", split out of RouteAppearanceTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

@testable import OpenHikes
import SwiftUI
import Testing

/// The third thing a hike's line carries, after its colour and its width: how
/// the line is drawn. Unlike the other two it is an enum stored as a string, so
/// there is a decode to get wrong as well as a value to draw wrong — and the
/// geometry it hands out is read by two drawers (the map renderer and the
/// picker's swatches), which is exactly the arrangement that rots when only one
/// of them is checked.
@Suite("Route line pattern")
struct RouteLinePatternTests {
    /// Every hike that existed before the choice did is drawn with whatever
    /// this is. It has to stay the line-with-arrows they were already drawn as,
    /// or an app update silently restyles every saved trail.
    @Test("the default is the line every existing hike was already drawn as")
    func defaultIsDirectional() {
        #expect(RouteLinePattern.default == .directional)
        #expect(Hike(title: "New", distanceMeters: 0).routeLinePattern == .directional)
    }

    @Test("a pattern round trips through its stored id", arguments: RouteLinePattern.allCases)
    func storedIDRoundTrips(pattern: RouteLinePattern) {
        #expect(RouteLinePattern(storedID: pattern.rawValue) == pattern)
    }

    /// The picker draws `displayOrder`, not `allCases`, so a pattern added to
    /// the enum and forgotten here would be drawable by the map and reachable
    /// by nobody.
    @Test("every pattern is offered by the picker, once")
    func displayOrderCoversEveryPattern() {
        #expect(Set(RouteLinePattern.displayOrder) == Set(RouteLinePattern.allCases))
        #expect(RouteLinePattern.displayOrder.count == RouteLinePattern.allCases.count)
    }

    /// A store written by a newer build — or a corrupted row — must still draw
    /// a route. Refusing to decode would leave the map blank for a trail that
    /// is otherwise perfectly intact.
    @Test("an unrecognised id falls back to the default", arguments: [
        "", "  ", "dashes", "SOLID", "arrow_heads", "🥾"
    ])
    func unknownIDFallsBack(id: String) {
        #expect(RouteLinePattern(storedID: id) == .default)
    }

    @Test("a pattern set on a hike is the pattern read back")
    func hikeStoresThePattern() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        hike.routeLinePattern = .dotted
        #expect(hike.routeLinePatternID == "dotted")
        #expect(hike.routeLinePattern == .dotted)

        // The id is what persists, so writing it directly must be read the same way.
        hike.routeLinePatternID = "arrowheads"
        #expect(hike.routeLinePattern == .arrowheads)
    }

    /// The two halves the renderer branches on. Arrowheads is the only pattern
    /// with no line at all — that is the whole difference between it and the
    /// line-with-arrows one.
    @Test("only the arrowheads pattern drops the line")
    func lineAndChevronCoverage() {
        for pattern in RouteLinePattern.allCases {
            #expect(pattern.drawsLine == (pattern != .arrowheads))
            #expect(pattern.drawsChevrons == (pattern == .directional || pattern == .arrowheads))
            #expect(pattern.chevronsUseRouteTint == (pattern == .arrowheads))
        }
    }

    @Test("an unbroken pattern has no dash", arguments: [
        RouteLinePattern.solid, .directional, .arrowheads
    ])
    func unbrokenPatternsHaveNoDash(pattern: RouteLinePattern) {
        #expect(pattern.dashLengths(forWidth: 3).isEmpty)
        #expect(pattern.lineCap == .round)
    }

    /// Both broken patterns derive their gap from the line width. A fixed gap
    /// is swallowed whole by a wide line — a 12 pt dotted route would draw as
    /// a solid one — which is the bug this pins.
    @Test("a broken pattern keeps its gaps at every line width", arguments: [
        RouteLinePattern.dashed, .dotted
    ])
    func brokenPatternsSurviveThickLines(pattern: RouteLinePattern) {
        for width in stride(from: 1.0, through: 12.0, by: 1.0) {
            let lengths = pattern.dashLengths(forWidth: width)
            #expect(lengths.count == 2)
            let (stroke, gap) = (lengths[0], lengths[1])
            #expect(stroke > 0, "a zero-length dash draws nothing at all")
            #expect(gap > width, "a round cap grows each stroke by half the width at either end")
        }
    }

    /// A dot is a dash shorter than the line is wide, rounded off by the cap.
    /// A dash is longer than it is wide, and squared off so the gap survives.
    @Test("dotted reads as dots and dashed reads as dashes")
    func dotsAndDashesDiffer() {
        let width = 6.0
        let dotted = RouteLinePattern.dotted.dashLengths(forWidth: width)
        let dashed = RouteLinePattern.dashed.dashLengths(forWidth: width)

        #expect(dotted[0] < width)
        #expect(RouteLinePattern.dotted.lineCap == .round)
        #expect(dashed[0] > width)
        #expect(RouteLinePattern.dashed.lineCap == .butt)
    }

    @Test("only a chevron-carrying pattern hands out chevron geometry")
    func chevronMetricsOnlyWhereDrawn() {
        for pattern in RouteLinePattern.allCases {
            #expect((pattern.chevronMetrics(forWidth: 4) != nil) == pattern.drawsChevrons)
        }
    }

    /// With no line to imply the path, the arrows have to carry it themselves:
    /// bigger, so they read on their own, and closer together, so the gaps
    /// between them still trace a route.
    @Test("arrowheads alone are larger and closer together than arrows on a line")
    func arrowheadsAreLargerAndCloser() throws {
        let onLine = try #require(RouteLinePattern.directional.chevronMetrics(forWidth: 4))
        let alone = try #require(RouteLinePattern.arrowheads.chevronMetrics(forWidth: 4))

        #expect(alone.halfLength > onLine.halfLength)
        #expect(alone.halfWidth > onLine.halfWidth)
        #expect(alone.strokeWidth > onLine.strokeWidth)
        #expect(alone.spacing < onLine.spacing)
    }

    /// A 1 pt line would otherwise get a chevron too small to see and a stroke
    /// thinner than a hairline.
    @Test("chevrons grow with the line but never below a legible minimum")
    func chevronMetricsHonourMinimums() throws {
        let thin = try #require(RouteLinePattern.directional.chevronMetrics(forWidth: 1))
        let thick = try #require(RouteLinePattern.directional.chevronMetrics(forWidth: 12))

        #expect(thin.halfLength >= 3)
        #expect(thin.halfWidth >= 3)
        #expect(thin.strokeWidth >= 1.5)
        #expect(thick.halfLength > thin.halfLength)
        #expect(thick.strokeWidth > thin.strokeWidth)
        #expect(thick.spacing == thin.spacing, "spacing is a screen distance, not a function of the width")
    }

    /// The rule both drawers share: a chevron riding a line is shaded against
    /// that line, so it reads on a dark route and on a light one.
    @Test("a chevron on a line contrasts with it")
    func chevronShadeContrasts() {
        let onWhite = RouteChevronShade.gray(
            forLuminance: RouteChevronShade.luminance(red: 1, green: 1, blue: 1)
        )
        let onBlack = RouteChevronShade.gray(
            forLuminance: RouteChevronShade.luminance(red: 0, green: 0, blue: 0)
        )
        #expect(onWhite < 0.5)
        #expect(onBlack > 0.5)

        // Green is the default tint and the one most routes are drawn in.
        let green = RouteChevronShade.luminance(red: 0.2, green: 0.78, blue: 0.35)
        #expect(RouteChevronShade.gray(forLuminance: green) == onBlack, "a mid-green takes the light chevron")
    }
}
