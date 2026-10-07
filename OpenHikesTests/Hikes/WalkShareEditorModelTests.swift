//
//  WalkShareEditorModelTests.swift
//  OpenHikesTests
//
//  What the share card editor settles when a finger lifts: a box's centre
//  stored as a share of the card, a scale kept in range, the photograph kept
//  covering the card — and every change remembered for the next card.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import SwiftUI
import Testing
import UIKit

@Suite("Walk share editor model")
struct WalkShareEditorModelTests {
    private static let canvas = CGSize(width: 400, height: 800)

    private static func model(suite: String) throws -> (WalkShareEditorModel, UserDefaults) {
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
        return (model, defaults)
    }

    @Test("a box let go is stored as a share of the card, and remembered")
    func placingStoresAShare() throws {
        let (model, defaults) = try Self.model(suite: "WalkShareEditorModelTests.place")

        model.place(.route, at: CGPoint(x: 100, y: 200))

        #expect(model.layout.route.center == CGPoint(x: 0.25, y: 0.25))
        #expect(WalkShareLayout.remembered(in: defaults) == model.layout)
    }

    @Test("a pinch past the limits stops at them")
    func resizingIsClamped() throws {
        let (model, _) = try Self.model(suite: "WalkShareEditorModelTests.resize")

        model.resize(.stats, to: 50)
        #expect(model.layout.stats.scale == WalkShareWidgetPlacement.scaleRange.upperBound)
        model.resize(.stats, to: 0)
        #expect(model.layout.stats.scale == WalkShareWidgetPlacement.scaleRange.lowerBound)
    }

    @Test("the photograph is never framed to show anything but itself")
    func photoFrameIsClamped() throws {
        let (model, _) = try Self.model(suite: "WalkShareEditorModelTests.photo")

        model.setPhotoFrame(WalkSharePhotoFrame(zoom: 0.1, offset: CGVector(dx: 3, dy: -3)))

        #expect(model.photoFrame == WalkSharePhotoFrame(zoom: 0.1, offset: CGVector(dx: 3, dy: -3))
            .clamped(image: CGSize(width: 400, height: 300), canvas: Self.canvas))
        #expect(model.photoFrame.zoom == 1)
    }

    @Test("styles, line colour and figures all reach the layout")
    func optionsReachTheLayout() throws {
        let (model, _) = try Self.model(suite: "WalkShareEditorModelTests.options")

        model.setStyle(.bare, of: .stats)
        model.setStyle(.card, of: .route)
        model.setLineColor(.trail)
        model.toggle(.speed)

        #expect(model.layout.statsStyle == .bare)
        #expect(model.layout.routeStyle == .card)
        #expect(model.layout.lineColor == .trail)
        #expect(!model.layout.shownStats.contains(.speed))
    }
}
