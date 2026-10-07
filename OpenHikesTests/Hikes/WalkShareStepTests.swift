//
//  WalkShareStepTests.swift
//  OpenHikesTests
//
//  The share card arranged without a finger, which is how VoiceOver arranges
//  it (#794): a box stepped, centred and resized by named actions, and the
//  photograph stepped and zoomed — each kept on the card by the same rules a
//  drag or a pinch is, and each read back as a ninth of the card.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import RealModule
import SwiftUI
import Testing
import UIKit

@Suite("Walk share steps")
struct WalkShareStepTests {
    private static let canvas = CGSize(width: 400, height: 800)
    private static let box = CGSize(width: 100, height: 60)
    /// A twentieth of the card's shorter side.
    private static let step: CGFloat = 20

    private static func model(suite: String) throws -> WalkShareEditorModel {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { _ in /* blank */ }
        let card = WalkShareCard(
            photo: photo,
            figures: WalkShareFigures(
                title: "Ridge Loop",
                walkedMeters: 1000,
                activeSeconds: 900,
                ascentMeters: nil,
                descentMeters: nil,
                completion: 1,
                startedAt: .now
            ),
            shape: .empty,
            tint: .green
        )
        let model = WalkShareEditorModel(card: card, defaults: defaults)
        model.setCanvasSize(canvas)
        return model
    }

    @Test("each step moves a box a twentieth of the card's width", arguments: WalkShareStep.allCases)
    func stepsMoveTheBox(step: WalkShareStep) {
        let center = CGPoint(x: 0.5, y: 0.5)
        let moved = WalkShareLayout.stepped(center: center, step, boxSize: Self.box, canvas: Self.canvas)

        #expect(moved.x == 200 + step.direction.dx * Self.step)
        #expect(moved.y == 400 + step.direction.dy * Self.step)
    }

    @Test("a step past an edge stops at it, as a drag does")
    func stepsStopAtTheEdge() {
        let flush = CGPoint(x: 50 / Self.canvas.width, y: 0.5)
        let moved = WalkShareLayout.stepped(center: flush, .left, boxSize: Self.box, canvas: Self.canvas)

        #expect(moved == CGPoint(x: 50, y: 400))
    }

    @Test("a step never covers the wordmark")
    func stepsKeepClearOfTheWordmark() {
        let usable = Self.canvas.height * (1 - WalkShareLayout.wordmarkBand)
        let low = CGPoint(x: 0.5, y: (usable - Self.box.height / 2) / Self.canvas.height)
        let moved = WalkShareLayout.stepped(center: low, .down, boxSize: Self.box, canvas: Self.canvas)

        #expect(moved.y + Self.box.height / 2 <= usable + 1e-9)
    }

    @Test("a step starts from where a box that outgrew its centre is drawn")
    func stepsStartFromTheDrawnBox() {
        // Stored flush with the left edge for a box half this wide.
        let stored = CGPoint(x: 25 / Self.canvas.width, y: 0.5)
        let moved = WalkShareLayout.stepped(center: stored, .right, boxSize: Self.box, canvas: Self.canvas)

        #expect(moved.x == 50 + Self.step)
    }

    @Test("a step near the middle passes it rather than sticking to it")
    func stepsDoNotSnap() {
        let nearMiddle = CGPoint(x: 195 / Self.canvas.width, y: 0.5)
        let moved = WalkShareLayout.stepped(center: nearMiddle, .right, boxSize: Self.box, canvas: Self.canvas)

        #expect(moved.x == 215)
    }

    @Test("Center puts a box on the middle line at the height it is drawn")
    func centersOnTheMiddleLine() {
        let centered = WalkShareLayout.centered(
            center: CGPoint(x: 0.1, y: 0.3),
            boxSize: Self.box,
            canvas: Self.canvas
        )

        #expect(centered == CGPoint(x: 200, y: 240))
    }

    @Test("a box is read back as the ninth of the card it is in")
    func regions() {
        let usable = Self.canvas.height * (1 - WalkShareLayout.wordmarkBand)

        #expect(WalkShareLayout.region(of: CGPoint(x: 10, y: 10), canvas: Self.canvas) == .topLeft)
        #expect(WalkShareLayout.region(of: CGPoint(x: 200, y: usable / 2), canvas: Self.canvas) == .center)
        #expect(WalkShareLayout.region(of: CGPoint(x: 390, y: usable - 1), canvas: Self.canvas) == .bottomRight)
        #expect(WalkShareLayout.region(of: CGPoint(x: 200, y: 10), canvas: Self.canvas) == .top)
        // Past the edges, as a centre in the wordmark band would be.
        #expect(WalkShareLayout.region(of: CGPoint(x: 500, y: 900), canvas: Self.canvas) == .bottomRight)
    }

    @Test("a step through the model is stored as a share of the card")
    func modelSteps() throws {
        let model = try Self.model(suite: "WalkShareStepTests.step")
        let before = model.layout.stats.center

        model.step(.stats, .down, boxSize: Self.box)

        #expect(model.layout.stats.center.x == before.x)
        #expect(
            model.layout.stats.center.y
                .isApproximatelyEqual(to: before.y + Self.step / Self.canvas.height, absoluteTolerance: 1e-9)
        )
    }

    @Test("Larger and Smaller step the scale and stop at its limits")
    func rescaleStepsAndClamps() throws {
        let model = try Self.model(suite: "WalkShareStepTests.rescale")
        let range = WalkShareWidgetPlacement.scaleRange

        model.rescale(.route, larger: true, boxSize: Self.box)
        #expect(model.layout.route.scale == WalkShareLayout.scaleStep)
        for _ in 0..<10 { model.rescale(.route, larger: true, boxSize: Self.box) }
        #expect(model.layout.route.scale == range.upperBound)
        for _ in 0..<10 { model.rescale(.route, larger: false, boxSize: Self.box) }
        #expect(model.layout.route.scale == range.lowerBound)
    }

    @Test("a box grown against an edge is pulled back onto the card at its new size")
    func rescalePullsBackFromTheEdge() throws {
        let model = try Self.model(suite: "WalkShareStepTests.edge")
        model.place(.route, at: CGPoint(x: 350, y: 400))

        model.rescale(.route, larger: true, boxSize: Self.box)

        let grownHalfWidth = Self.box.width * WalkShareLayout.scaleStep / 2
        #expect(
            (model.layout.route.center.x * Self.canvas.width)
                .isApproximatelyEqual(to: Self.canvas.width - grownHalfWidth, absoluteTolerance: 1e-9)
        )
    }

    @Test("the photograph steps and zooms, and never shows past its edge")
    func photoStepsAndZooms() throws {
        let model = try Self.model(suite: "WalkShareStepTests.photo")

        // A landscape photograph on an upright card fills its height exactly.
        model.stepPhoto(.up)
        #expect(model.photoFrame == WalkSharePhotoFrame(), "a photograph only just as tall as the card cannot go up")
        model.stepPhoto(.left)
        #expect(model.photoFrame.offset.dx == -WalkShareLayout.stepFraction, "but it is far wider than the card")

        model.zoomPhoto(in: true)
        #expect(model.photoFrame.zoom == CGFloat(WalkShareLayout.scaleStep))
        model.stepPhoto(.up)
        #expect(model.photoFrame.offset.dy == -WalkShareLayout.stepFraction)
        for _ in 0..<40 { model.stepPhoto(.up) }
        // 1000 points tall now, so 100 of them past each edge of the card.
        #expect(model.photoFrame.offset.dy.isApproximatelyEqual(to: -100 / Self.canvas.height, absoluteTolerance: 1e-9))

        for _ in 0..<10 { model.zoomPhoto(in: false) }
        #expect(model.photoFrame.zoom == WalkSharePhotoFrame.zoomRange.lowerBound)
        #expect(model.photoFrame.offset.dy == 0, "zoomed back out, it is as tall as the card again")
    }

    @Test("what VoiceOver says after a step names the ninth and the size")
    func spokenPlacement() throws {
        let model = try Self.model(suite: "WalkShareStepTests.spoken")
        model.place(.stats, at: CGPoint(x: 60, y: 40))
        model.resize(.stats, to: 1.5)

        let spoken = model.spokenPlacement(of: .stats)

        #expect(spoken.hasPrefix(WalkShareRegion.topLeft.spoken))
        #expect(spoken.contains("150"))
    }
}
