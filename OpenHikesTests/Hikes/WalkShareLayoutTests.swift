//
//  WalkShareLayoutTests.swift
//  OpenHikesTests
//
//  The rules that keep a share card's boxes on the card: never off an edge,
//  never over the wordmark, pulled onto the middle when close to it, and a
//  stats box that holds between one and four figures whatever the menu does.
//  And the layout's memory, which has to survive a value it cannot read.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Walk share layout")
struct WalkShareLayoutTests {
    private static let canvas = CGSize(width: 400, height: 800)
    private static let box = CGSize(width: 100, height: 60)

    @Test("a box dragged past an edge stops at it")
    func clampsToTheEdges() {
        let topLeft = WalkShareLayout.clampedCenter(CGPoint(x: -50, y: -50), boxSize: Self.box, canvas: Self.canvas)
        let farRight = WalkShareLayout.clampedCenter(CGPoint(x: 900, y: 300), boxSize: Self.box, canvas: Self.canvas)

        #expect(topLeft == CGPoint(x: 50, y: 30))
        #expect(farRight == CGPoint(x: 350, y: 300))
    }

    @Test("no box covers the wordmark along the bottom")
    func keepsClearOfTheWordmark() {
        let bottom = WalkShareLayout.clampedCenter(CGPoint(x: 200, y: 800), boxSize: Self.box, canvas: Self.canvas)
        let usable = Self.canvas.height * (1 - WalkShareLayout.wordmarkBand)

        #expect(bottom.y + Self.box.height / 2 <= usable + 1e-9)
    }

    @Test("a box wider than the card is centred on it")
    func oversizedBoxIsCentred() {
        let wide = CGSize(width: 500, height: 60)
        let center = WalkShareLayout.clampedCenter(CGPoint(x: 10, y: 300), boxSize: wide, canvas: Self.canvas)

        #expect(center.x == Self.canvas.width / 2)
    }

    @Test("close to the middle snaps to it; further does not")
    func snapsToTheMiddle() {
        let near = WalkShareLayout.snapped(CGPoint(x: 205, y: 120), canvas: Self.canvas)
        let far = WalkShareLayout.snapped(CGPoint(x: 240, y: 120), canvas: Self.canvas)

        #expect(near.isSnapped)
        #expect(near.center == CGPoint(x: 200, y: 120))
        #expect(!far.isSnapped)
        #expect(far.center == CGPoint(x: 240, y: 120))
    }

    @Test("a box that outgrew its stored centre is drawn on the card, and drags from there")
    func dragsFromWhereTheBoxIsDrawn() {
        // Stored flush with the left edge for a box half this wide.
        let stored = CGPoint(x: 25.0 / Self.canvas.width, y: 0.5)

        let atRest = WalkShareLayout.target(center: stored, translation: .zero, boxSize: Self.box, canvas: Self.canvas)
        let dragged = WalkShareLayout.target(
            center: stored,
            translation: CGSize(width: 30, height: 0),
            boxSize: Self.box,
            canvas: Self.canvas
        )

        #expect(atRest.center == CGPoint(x: 50, y: 400))
        #expect(!atRest.isSnapped)
        #expect(dragged.center == CGPoint(x: 80, y: 400), "the finger's 30 points all move the box")
    }

    @Test("a box at rest near the middle is not snapped there, only a dragged one")
    func snapsOnlyWhileDragged() {
        let stored = CGPoint(x: 205 / Self.canvas.width, y: 0.5)

        let atRest = WalkShareLayout.target(center: stored, translation: .zero, boxSize: Self.box, canvas: Self.canvas)
        let nudged = WalkShareLayout.target(
            center: stored,
            translation: CGSize(width: 1, height: 0),
            boxSize: Self.box,
            canvas: Self.canvas
        )

        #expect(atRest.center.x.isApproximatelyEqual(to: 205, absoluteTolerance: 1e-9))
        #expect(!atRest.isSnapped)
        #expect(nudged.center.x == 200)
        #expect(nudged.isSnapped)
    }

    @Test("a fifth figure is refused, and so is switching off the last")
    func figureLimits() {
        let full = WalkShareLayout.standard
        #expect(full.shownStats.count == WalkShareStat.maximumShown)
        #expect(full.toggling(.date) == full)

        var single = full
        single.shownStats = [.time]
        #expect(single.toggling(.time) == single)
    }

    @Test("a figure switched on takes its place in the menu's order")
    func figuresKeepTheMenuOrder() {
        var layout = WalkShareLayout.standard
        layout.shownStats = [.time, .distance]

        #expect(layout.toggling(.ascent).shownStats == [.distance, .ascent, .time])
        #expect(layout.toggling(.distance).shownStats == [.time])
    }

    @Test("the layout comes back as it was left")
    func remembersTheLayout() throws {
        let defaults = try #require(UserDefaults(suiteName: "WalkShareLayoutTests.remembers"))
        defaults.removePersistentDomain(forName: "WalkShareLayoutTests.remembers")
        var layout = WalkShareLayout.standard
        layout.stats.center = CGPoint(x: 0.25, y: 0.75)
        layout.routeStyle = .card
        layout.lineColor = .trail
        layout.remember(in: defaults)

        #expect(WalkShareLayout.remembered(in: defaults) == layout)
    }

    @Test("nothing remembered, or nothing readable, is the standard layout")
    func unreadableIsStandard() throws {
        let defaults = try #require(UserDefaults(suiteName: "WalkShareLayoutTests.unreadable"))
        defaults.removePersistentDomain(forName: "WalkShareLayoutTests.unreadable")
        #expect(WalkShareLayout.remembered(in: defaults) == .standard)

        defaults.set(Data("not a layout".utf8), forKey: SettingsKey.walkShareLayout)
        #expect(WalkShareLayout.remembered(in: defaults) == .standard)
    }

    @Test("a remembered value outside the rules is brought back inside them")
    func rememberedValuesAreClamped() throws {
        let defaults = try #require(UserDefaults(suiteName: "WalkShareLayoutTests.clamped"))
        defaults.removePersistentDomain(forName: "WalkShareLayoutTests.clamped")
        var layout = WalkShareLayout.standard
        layout.route.scale = 40
        layout.shownStats = []
        layout.remember(in: defaults)

        let restored = WalkShareLayout.remembered(in: defaults)
        #expect(restored.route.scale == WalkShareWidgetPlacement.scaleRange.upperBound)
        #expect(restored.shownStats == WalkShareStat.defaultShown)
    }
}
